import AVFoundation
import Foundation
import ObjectiveC
import UniformTypeIdentifiers

/// Streams progressive media through a custom URL scheme in bounded, validated
/// byte ranges, and stages small complete files into the disk cache.
///
/// Concurrent requests for one request identity share one transfer. Memory is
/// bounded by `MediaTransferBudget`; disk staging only happens under a cache
/// reservation, so media larger than the cache budget streams without being
/// cached instead of growing a temporary file.
final class CachingResourceLoader: NSObject {
  static let scheme = "nfpcache"

  /// Upper bound on bytes handed to a single `respond(with:)` call so open
  /// ended requests never materialise a whole cached file in memory.
  static let chunkSize = MediaTransferBudget.Limits().chunkSize

  static let errorDomain = "native_feed_player.cache"

  enum ErrorCode: Int {
    case cacheIO = -1
    case protocolViolation = -2
    case representationChanged = -3
    case unsupportedResponse = -4
  }

  private struct RequestContext {
    let requestIdentity: String
    let policy: SourceRequestPolicy
    let client: MediaDiskCache.Client?
  }

  private final class AssetContext {
    weak var loader: CachingResourceLoader?
    let url: URL

    init(loader: CachingResourceLoader, url: URL) {
      self.loader = loader
      self.url = url
    }

    deinit {
      loader?.releaseURL(url)
    }
  }

  private static var assetContextKey: UInt8 = 0

  /// Wraps a remote URL so AVFoundation routes it through this delegate.
  /// The opaque identity in the scheme prevents assets with different request
  /// credentials from sharing loader or disk state.
  static func interceptURL(
    for uri: String,
    headers: [String: String] = [:],
    cacheKey: String? = nil,
    trustedOrigins: [String] = []
  ) -> URL? {
    let identity = MediaCacheIdentity.make(
      uri: uri, headers: headers, cacheKey: cacheKey, trustedOrigins: trustedOrigins
    )
    guard var components = URLComponents(string: uri), let originalScheme = components.scheme
    else {
      return nil
    }
    components.scheme = "\(scheme)-\(originalScheme)-\(identity)"
    return components.url
  }

  /// Restores the real URL from an intercepted one.
  static func originalURL(from url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let originalScheme = interceptedParts(from: components.scheme).scheme
    else {
      return nil
    }
    components.scheme = originalScheme
    return components.url
  }

  static func identity(from url: URL) -> String? {
    guard let scheme = URLComponents(url: url, resolvingAgainstBaseURL: false)?.scheme else {
      return nil
    }
    return interceptedParts(from: scheme).identity
  }

  /// Exposed internally for focused response validation tests.
  static func isSuccessfulHTTPStatus(_ statusCode: Int) -> Bool {
    (200...299).contains(statusCode)
  }

  static func contentType(forMimeType mimeType: String?) -> String? {
    guard let mimeType else {
      return nil
    }
    return UTType(mimeType: mimeType)?.identifier
  }

  static func normalizedContentType(_ contentType: String?) -> String? {
    guard let contentType else {
      return nil
    }
    return contentType.contains("/")
      ? Self.contentType(forMimeType: contentType)
      : contentType
  }

  /// Parsed `Content-Range`: `bytes a-b/total` or `bytes */total`.
  struct ContentRange: Equatable {
    let start: Int64?
    let end: Int64?
    let total: Int64?
  }

  /// Strict `Content-Range` parsing with overflow and ordering checks.
  static func parseContentRange(_ value: String?) -> ContentRange? {
    guard let value = value?.trimmingCharacters(in: .whitespaces),
      value.lowercased().hasPrefix("bytes ")
    else {
      return nil
    }
    let spec = value.dropFirst("bytes ".count)
    let parts = spec.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else {
      return nil
    }
    var total: Int64?
    if parts[1] != "*" {
      guard let parsed = Int64(parts[1]), parsed >= 0 else {
        return nil
      }
      total = parsed
    }
    if parts[0] == "*" {
      return total == nil ? nil : ContentRange(start: nil, end: nil, total: total)
    }
    let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
      start >= 0, end >= start
    else {
      return nil
    }
    if let total, end >= total {
      return nil
    }
    return ContentRange(start: start, end: end, total: total)
  }

  /// Bytes to serve in the next chunk of a request, or 0 when the request is
  /// already satisfied. Pure so the boundary cases are unit-testable.
  static func chunkPlan(
    requestedLength: Int64,
    alreadyServed: Int64,
    currentOffset: Int64,
    byteCount: Int64,
    requestsAllDataToEndOfResource: Bool = false
  ) -> Int64 {
    let remainingInRequest = requestsAllDataToEndOfResource
      ? Int64.max
      : requestedLength - alreadyServed
    let remainingInFile = byteCount - currentOffset
    return max(0, min(remainingInRequest, remainingInFile, Int64(chunkSize)))
  }

  final class Transfer {
    let identity: String
    let requestIdentity: String
    let originalURL: URL
    let policy: SourceRequestPolicy
    let client: MediaDiskCache.Client?
    var pending: [AVAssetResourceLoadingRequest] = []
    var contentLength: Int64?
    var contentType: String?
    var validator: String?
    var rangesSupported: Bool?
    var buffer = MediaRangeBuffer()
    var staging: Staging?
    var stagingDeclined = false
    var cached: (pin: MediaDiskCache.PinnedFile, handle: FileHandle)?
    var fetch: Fetch?
    var waiterId: UUID?
    var deliveryScheduled = false
    var closed = false

    init(
      identity: String, requestIdentity: String, originalURL: URL,
      policy: SourceRequestPolicy, client: MediaDiskCache.Client?
    ) {
      self.identity = identity
      self.requestIdentity = requestIdentity
      self.originalURL = originalURL
      self.policy = policy
      self.client = client
    }
  }

  final class Staging {
    let reservation: MediaDiskCache.Reservation
    let writeHandle: FileHandle
    let readHandle: FileHandle
    var coverage = ByteRangeSet()
    var adopting = false

    init(reservation: MediaDiskCache.Reservation, writeHandle: FileHandle, readHandle: FileHandle) {
      self.reservation = reservation
      self.writeHandle = writeHandle
      self.readHandle = readHandle
    }
  }

  final class Fetch {
    let task: URLSessionDataTask
    let start: Int64
    /// Inclusive end sent in the Range header; nil when no range was sent.
    let requestedEnd: Int64?
    let isFill: Bool
    var responded = false
    /// Absolute offset of the next byte the response delivers.
    var position: Int64 = 0
    /// Bytes before this offset are discarded (servers that ignore Range).
    var discardUntil: Int64 = 0
    /// Exclusive end the response declared, when known.
    var expectedEnd: Int64?
    var sequential = false

    init(task: URLSessionDataTask, start: Int64, requestedEnd: Int64?, isFill: Bool) {
      self.task = task
      self.start = start
      self.requestedEnd = requestedEnd
      self.isFill = isFill
    }
  }

  private let queue: DispatchQueue
  private let sessionConfiguration: URLSessionConfiguration
  private let cache: MediaDiskCache
  let budget: MediaTransferBudget
  /// Created on first use and only touched on `queue` (or after shutdown).
  private var sessionStorage: URLSession?

  private var transfers: [String: Transfer] = [:]
  private var transfersByTask: [Int: Transfer] = [:]
  private var contextsByToken: [String: RequestContext] = [:]
  var onFailure: ((String, Error) -> Void)?

  init(
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    queue: DispatchQueue = DispatchQueue(label: "native_feed_player.resourceloader"),
    cache: MediaDiskCache = .shared,
    budget: MediaTransferBudget = .shared
  ) {
    sessionConfiguration.urlCache = nil
    sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
    sessionConfiguration.httpShouldSetCookies = false
    sessionConfiguration.httpCookieAcceptPolicy = .never
    self.sessionConfiguration = sessionConfiguration
    self.queue = queue
    self.cache = cache
    self.budget = budget
    super.init()
  }

  /// URLSession delegate callbacks run directly on `queue`: no hop, and no
  /// unbounded backlog of queued closures retaining received data.
  private var session: URLSession {
    if let sessionStorage {
      return sessionStorage
    }
    let delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.underlyingQueue = queue
    let created = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: delegateQueue)
    sessionStorage = created
    return created
  }

  /// Registers the short-lived request context before AVFoundation can ask the
  /// resource loader for bytes.
  func prepareURL(
    for uri: String,
    headers: [String: String],
    cacheKey: String? = nil,
    trustedOrigins: [String] = [],
    client: MediaDiskCache.Client? = nil
  ) -> URL? {
    guard let intercepted = CachingResourceLoader.interceptURL(
      for: uri,
      headers: headers,
      cacheKey: cacheKey,
      trustedOrigins: trustedOrigins
    ),
      let identity = CachingResourceLoader.identity(from: intercepted)
    else {
      return nil
    }
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    guard var components = URLComponents(url: intercepted, resolvingAgainstBaseURL: false),
      let interceptedScheme = components.scheme
    else {
      return nil
    }
    components.scheme = "\(interceptedScheme)-\(token)"
    guard let prepared = components.url else {
      return nil
    }
    let context = RequestContext(
      requestIdentity: identity + MediaCacheIdentity.make(uri: uri, headers: headers),
      policy: SourceRequestPolicy(sourceURI: uri, headers: headers, trustedOrigins: trustedOrigins),
      client: client
    )
    queue.async {
      self.contextsByToken[token] = context
    }
    return prepared
  }

  func releaseURL(_ url: URL) {
    guard let token = Self.interceptedParts(from: url.scheme).token else {
      return
    }
    queue.async {
      // A retry may have installed a fresh context while adoption ran.
      guard let context = self.contextsByToken.removeValue(forKey: token) else {
        return
      }
      if let transfer = self.transfers[context.requestIdentity],
        !self.contextsByToken.values.contains(where: { $0.requestIdentity == context.requestIdentity })
      {
        self.close(transfer)
      }
    }
  }

  func prepareAsset(
    for uri: String,
    headers: [String: String],
    cacheKey: String? = nil,
    trustedOrigins: [String] = [],
    client: MediaDiskCache.Client? = nil
  ) -> AVURLAsset? {
    guard let url = prepareURL(
      for: uri, headers: headers, cacheKey: cacheKey, trustedOrigins: trustedOrigins, client: client
    ) else {
      return nil
    }
    let asset = AVURLAsset(url: url)
    objc_setAssociatedObject(
      asset, &Self.assetContextKey, AssetContext(loader: self, url: url),
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    asset.resourceLoader.setDelegate(self, queue: queue)
    return asset
  }

  func contextCountForTesting(completion: @escaping (Int) -> Void) {
    queue.async {
      completion(self.contextsByToken.count)
    }
  }

  func transferCountForTesting(completion: @escaping (Int) -> Void) {
    queue.async {
      completion(self.transfers.count)
    }
  }

  /// Ends every transfer and discards unfinished staging; live contexts stay
  /// registered so their assets can start over.
  func cancelAll(completion: (() -> Void)? = nil) {
    queue.async {
      for transfer in Array(self.transfers.values) {
        self.close(transfer)
      }
      completion?()
    }
  }

  /// Explicit eviction: ends transfers for `identities` and discards their
  /// unfinished staging so nothing repopulates the evicted entries.
  func cancel(identities: Set<String>, completion: @escaping () -> Void) {
    queue.async {
      for transfer in Array(self.transfers.values) where identities.contains(transfer.identity) {
        self.close(transfer)
      }
      completion()
    }
  }

  /// Breaks URLSession's delegate retention during manager teardown.
  func shutdown() {
    queue.sync {
      for transfer in Array(transfers.values) {
        close(transfer)
      }
      contextsByToken.removeAll()
    }
    sessionStorage?.invalidateAndCancel()
  }

  deinit {
    sessionStorage?.invalidateAndCancel()
  }

  private static func interceptedParts(from interceptedScheme: String?) -> (
    scheme: String?, identity: String?, token: String?
  ) {
    guard let interceptedScheme, interceptedScheme.hasPrefix("\(scheme)-") else {
      return (nil, nil, nil)
    }
    var remainder = String(interceptedScheme.dropFirst(scheme.count + 1))
    var token: String?
    if let separator = remainder.lastIndex(of: "-") {
      let suffix = String(remainder[remainder.index(after: separator)...])
      if suffix.count == 32, suffix.allSatisfy({ $0.isHexDigit }) {
        token = suffix.lowercased()
        remainder = String(remainder[..<separator])
      }
    }
    guard let separator = remainder.lastIndex(of: "-") else {
      // Accept the old URL shape only to restore a URL. It has no v2 identity
      // and therefore can never address a cached entry.
      return (remainder, nil, nil)
    }
    let identity = String(remainder[remainder.index(after: separator)...])
    let originalScheme = String(remainder[..<separator])
    guard identity.count == 64, identity.allSatisfy({ $0.isHexDigit }) else {
      return (remainder, nil, nil)
    }
    return (originalScheme, identity.lowercased(), token)
  }

  static func error(_ code: ErrorCode, _ description: String) -> NSError {
    NSError(domain: errorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: description])
  }

  private static func cancellationError() -> NSError {
    NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: [NSLocalizedDescriptionKey: "Media cache request was cancelled."]
    )
  }

  private static func httpError(statusCode: Int) -> NSError {
    NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorBadServerResponse,
      userInfo: [
        NSLocalizedDescriptionKey: "Media request failed with HTTP status \(statusCode).",
        "HTTPStatusCode": statusCode,
      ]
    )
  }
}

// MARK: - AVAssetResourceLoaderDelegate

extension CachingResourceLoader: AVAssetResourceLoaderDelegate {
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard let interceptedURL = loadingRequest.request.url,
      let originalURL = CachingResourceLoader.originalURL(from: interceptedURL),
      let identity = CachingResourceLoader.identity(from: interceptedURL)
    else {
      return false
    }

    // All disk IO and request completion happens on `queue`; the delegate
    // queue returns immediately so AVFoundation is never blocked behind a
    // cache read.
    queue.async {
      let token = Self.interceptedParts(from: interceptedURL.scheme).token
      let context = token.flatMap { self.contextsByToken[$0] }
      guard token == nil || context != nil else {
        loadingRequest.finishLoading(with: Self.cancellationError())
        return
      }
      let requestIdentity = context?.requestIdentity
        ?? identity + MediaCacheIdentity.make(uri: originalURL.absoluteString, headers: [:])
      let transfer = self.transfers[requestIdentity] ?? self.makeTransfer(
        identity: identity, requestIdentity: requestIdentity, originalURL: originalURL,
        context: context
      )
      transfer.pending.append(loadingRequest)
      self.pump(transfer)
    }
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    queue.async {
      for transfer in Array(self.transfers.values) where
        transfer.pending.contains(where: { $0 === loadingRequest })
      {
        // AVFoundation already owns the cancelled request's terminal state, so
        // do not invoke it again.
        transfer.pending.removeAll { $0 === loadingRequest }
        self.pump(transfer)
      }
    }
  }
}

// MARK: - Transfer scheduling

extension CachingResourceLoader {
  private func makeTransfer(
    identity: String, requestIdentity: String, originalURL: URL, context: RequestContext?
  ) -> Transfer {
    let transfer = Transfer(
      identity: identity, requestIdentity: requestIdentity, originalURL: originalURL,
      policy: context?.policy
        ?? SourceRequestPolicy(sourceURI: originalURL.absoluteString, headers: [:], trustedOrigins: []),
      client: context?.client
    )
    if let client = context?.client, client.enabled,
      let cached = cache.pinnedFile(forIdentity: identity, client: client)
    {
      transfer.cached = (pin: cached.0, handle: cached.1)
      transfer.contentLength = cached.0.byteCount
      transfer.contentType = cached.0.contentType
      transfer.rangesSupported = true
    }
    transfers[requestIdentity] = transfer
    return transfer
  }

  private var limits: MediaTransferBudget.Limits { budget.limits }

  /// Serves what is available, then decides what to fetch next.
  fileprivate func pump(_ transfer: Transfer) {
    guard !transfer.closed else {
      return
    }
    serve(transfer)
    guard !transfer.closed else {
      return
    }
    let demand = nextDemand(transfer)
    if let fetch = transfer.fetch {
      if fetchServesDemand(fetch, in: transfer) {
        return
      }
      if demand != nil || (fetch.sequential && !keepsSequentialFetch(transfer)) {
        cancelFetch(transfer)
      } else {
        return
      }
    }
    if let demand {
      startFetch(transfer, at: demand, fill: false)
    } else if let gap = fillGap(transfer) {
      startFetch(transfer, at: gap, fill: true)
    } else if transfer.pending.isEmpty, !hasContext(transfer) {
      close(transfer)
    }
  }

  private func hasContext(_ transfer: Transfer) -> Bool {
    contextsByToken.values.contains { $0.requestIdentity == transfer.requestIdentity }
  }

  /// Delivers stored bytes to pending requests and finishes satisfied ones.
  private func serve(_ transfer: Transfer) {
    var stillPending: [AVAssetResourceLoadingRequest] = []
    var needsAnotherPass = false
    for request in transfer.pending {
      if request.isCancelled {
        continue
      }
      let length = transfer.contentLength
      if let info = request.contentInformationRequest {
        guard let length else {
          stillPending.append(request)
          continue
        }
        info.contentType = Self.normalizedContentType(transfer.contentType) ?? AVFileType.mp4.rawValue
        info.contentLength = length
        info.isByteRangeAccessSupported = true
      }
      guard let dataRequest = request.dataRequest else {
        request.finishLoading()
        continue
      }
      switch completion(of: dataRequest, length: length) {
      case .complete:
        request.finishLoading()
        continue
      case .pastEnd:
        request.finishLoading(with: Self.error(.protocolViolation, "Media ended before the requested range."))
        continue
      case .needsData:
        break
      }
      let offset = dataRequest.currentOffset
      let remaining = remainingBytes(dataRequest, length: length)
      guard let data = available(transfer, at: offset, maxLength: Int(min(remaining, Int64(limits.chunkSize)))),
        !data.isEmpty
      else {
        stillPending.append(request)
        continue
      }
      dataRequest.respond(with: data)
      guard dataRequest.currentOffset > offset else {
        request.finishLoading(with: Self.error(.cacheIO, "Media request made no delivery progress."))
        continue
      }
      if completion(of: dataRequest, length: length) == .complete {
        request.finishLoading()
      } else {
        stillPending.append(request)
        needsAnotherPass = true
      }
    }
    transfer.pending = stillPending
    if needsAnotherPass, !transfer.deliveryScheduled {
      // One chunk per request per pass keeps the queue responsive.
      transfer.deliveryScheduled = true
      queue.async {
        transfer.deliveryScheduled = false
        self.pump(transfer)
      }
    }
  }

  private enum RequestCompletion: Equatable {
    case complete
    case pastEnd
    case needsData
  }

  private func completion(of request: AVAssetResourceLoadingDataRequest, length: Int64?) -> RequestCompletion {
    let offset = request.currentOffset
    if request.requestsAllDataToEndOfResource {
      guard let length else {
        return .needsData
      }
      return offset >= length ? .complete : .needsData
    }
    let end = request.requestedOffset + Int64(request.requestedLength)
    if offset >= end {
      return .complete
    }
    if let length, offset >= length {
      return .pastEnd
    }
    return .needsData
  }

  private func remainingBytes(_ request: AVAssetResourceLoadingDataRequest, length: Int64?) -> Int64 {
    let toRequestEnd = request.requestsAllDataToEndOfResource
      ? Int64.max
      : request.requestedOffset + Int64(request.requestedLength) - request.currentOffset
    let toResourceEnd = length.map { $0 - request.currentOffset } ?? Int64.max
    return max(0, min(toRequestEnd, toResourceEnd))
  }

  /// Bytes at `offset` from the cached file, staging coverage, or memory.
  private func available(_ transfer: Transfer, at offset: Int64, maxLength: Int) -> Data? {
    guard maxLength > 0 else {
      return nil
    }
    if let cached = transfer.cached, offset < cached.pin.byteCount {
      return read(cached.handle, at: offset, count: Int(min(Int64(maxLength), cached.pin.byteCount - offset)))
    }
    if let staging = transfer.staging, let end = staging.coverage.end(containing: offset) {
      return read(staging.readHandle, at: offset, count: Int(min(Int64(maxLength), end - offset)))
    }
    return transfer.buffer.read(at: offset, maxLength: maxLength)
  }

  private func read(_ handle: FileHandle, at offset: Int64, count: Int) -> Data? {
    do {
      try handle.seekCompat(toOffset: UInt64(offset))
      return try handle.readCompat(upToCount: count)
    } catch {
      return nil
    }
  }

  /// Offset the newest waiting request needs next, or nil when all pending
  /// requests can be served from stored bytes. Newest first, so a seek wins
  /// over the reads it superseded.
  private func nextDemand(_ transfer: Transfer) -> Int64? {
    guard transfer.pending.contains(where: { !$0.isCancelled }) else {
      return nil
    }
    if transfer.contentLength == nil {
      // Until the size is known, spool contiguously from the start; EOF
      // then reveals the length every request depends on.
      return transfer.buffer.contiguousEnd(from: 0) ?? 0
    }
    for request in transfer.pending.reversed() where !request.isCancelled {
      guard let dataRequest = request.dataRequest else {
        continue
      }
      guard completion(of: dataRequest, length: transfer.contentLength) == .needsData else {
        continue
      }
      let offset = dataRequest.currentOffset
      if available(transfer, at: offset, maxLength: 1) == nil {
        return offset
      }
    }
    return nil
  }

  /// Whether the active response will reach a waiting request soon.
  private func fetchServesDemand(_ fetch: Fetch, in transfer: Transfer) -> Bool {
    if transfer.contentLength == nil {
      // Discovering the length: the active response is the spool.
      return true
    }
    let position = max(fetch.position, fetch.discardUntil, fetch.start)
    let end = fetch.expectedEnd ?? fetch.requestedEnd.map { $0 + 1 } ?? Int64.max
    let reach = position + Int64(limits.fetchSize)
    return transfer.pending.contains { request in
      guard !request.isCancelled, let dataRequest = request.dataRequest else {
        return false
      }
      let offset = dataRequest.currentOffset
      return offset >= position && offset < end && offset < reach
        && completion(of: dataRequest, length: transfer.contentLength) == .needsData
    }
  }

  /// A sequential (Range-ignoring) response keeps streaming while it fills
  /// reserved staging or an unknown-length spool, or while memory remains.
  private func keepsSequentialFetch(_ transfer: Transfer) -> Bool {
    if transfer.contentLength == nil {
      return true
    }
    if let staging = transfer.staging, !staging.adopting {
      return true
    }
    return transfer.buffer.byteCount < limits.perResourceBytes
  }

  /// Next uncached range of a reserved staging file, fetched at low priority
  /// once no request is waiting so small clips become fully cached.
  private func fillGap(_ transfer: Transfer) -> Int64? {
    guard let staging = transfer.staging, !staging.adopting, let length = transfer.contentLength,
      hasContext(transfer)
    else {
      return nil
    }
    return staging.coverage.firstGap(below: length)
  }

  private func startFetch(_ transfer: Transfer, at start: Int64, fill: Bool) {
    if let length = transfer.contentLength, start >= length {
      return
    }
    guard budget.acquireTransfer() || (!fill && preemptFill() && budget.acquireTransfer()) else {
      if !fill {
        waitForTransferSlot(transfer)
      }
      return
    }
    if let waiterId = transfer.waiterId {
      budget.removeWaiter(id: waiterId)
      transfer.waiterId = nil
    }
    var request = URLRequest(url: transfer.originalURL)
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    var requestedEnd: Int64?
    if transfer.rangesSupported != false {
      var end = start + Int64(limits.fetchSize) - 1
      if let length = transfer.contentLength {
        end = min(end, length - 1)
      }
      request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
      if start > 0, let validator = transfer.validator {
        request.setValue(validator, forHTTPHeaderField: "If-Range")
      }
      requestedEnd = end
    }
    transfer.policy.apply(to: &request)
    let task = session.dataTask(with: request)
    task.priority = fill ? URLSessionTask.lowPriority : URLSessionTask.highPriority
    let fetch = Fetch(task: task, start: start, requestedEnd: requestedEnd, isFill: fill)
    transfer.fetch = fetch
    transfersByTask[task.taskIdentifier] = transfer
    task.resume()
  }

  private func waitForTransferSlot(_ transfer: Transfer) {
    guard transfer.waiterId == nil else {
      return
    }
    let id = UUID()
    transfer.waiterId = id
    budget.enqueueWaiter(id: id, queue: queue) { [weak self, weak transfer] in
      guard let self, let transfer, transfer.waiterId == id else {
        return
      }
      transfer.waiterId = nil
      self.pump(transfer)
    }
  }

  /// Cancels this loader's lowest-priority work for a waiting request.
  private func preemptFill() -> Bool {
    guard let victim = transfers.values.first(where: { $0.fetch?.isFill == true }) else {
      return false
    }
    cancelFetch(victim)
    return true
  }

  private func cancelFetch(_ transfer: Transfer) {
    guard let fetch = transfer.fetch else {
      return
    }
    transfer.fetch = nil
    transfersByTask.removeValue(forKey: fetch.task.taskIdentifier)
    fetch.task.cancel()
    budget.releaseTransfer()
  }

  /// Fails every waiting request and reports non-cancellation failures.
  private func fail(_ transfer: Transfer, _ error: Error) {
    guard !transfer.closed else {
      return
    }
    for request in transfer.pending where !request.isCancelled {
      request.finishLoading(with: error)
    }
    transfer.pending.removeAll()
    let nsError = error as NSError
    if nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled {
      onFailure?(transfer.requestIdentity, error)
    }
    close(transfer)
  }

  /// Releases every resource a transfer holds. Unfinished staging is
  /// discarded; an adopted or cached entry is unpinned.
  private func close(_ transfer: Transfer) {
    guard !transfer.closed else {
      return
    }
    transfer.closed = true
    cancelFetch(transfer)
    if let waiterId = transfer.waiterId {
      budget.removeWaiter(id: waiterId)
      transfer.waiterId = nil
    }
    for request in transfer.pending where !request.isCancelled {
      request.finishLoading(with: Self.cancellationError())
    }
    transfer.pending.removeAll()
    budget.releaseMemory(transfer.buffer.removeAll())
    if let staging = transfer.staging {
      try? staging.writeHandle.closeCompat()
      try? staging.readHandle.closeCompat()
      if !staging.adopting {
        cache.cancel(staging.reservation)
      }
      transfer.staging = nil
    }
    if let cached = transfer.cached {
      try? cached.handle.closeCompat()
      cache.unpin(cached.pin)
      transfer.cached = nil
    }
    if transfers[transfer.requestIdentity] === transfer {
      transfers.removeValue(forKey: transfer.requestIdentity)
    }
  }
}

// MARK: - Received data

extension CachingResourceLoader {
  /// Hands bytes straight to requests positioned inside them, writes them to
  /// reserved staging, and retains them in memory within budget.
  fileprivate func receive(_ data: Data, at offset: Int64, in transfer: Transfer) {
    deliverDirectly(data, at: offset, in: transfer)
    let wroteToStaging = writeToStaging(data, at: offset, in: transfer)
    guard !transfer.closed else {
      return
    }
    if transfer.contentLength == nil {
      // Unknown length: everything must be held until EOF reveals the size.
      guard retain(data, at: offset, in: transfer, mandatory: true) else {
        fail(transfer, Self.error(
          .unsupportedResponse,
          "Media response has no declared length and exceeds the streaming buffer."
        ))
        return
      }
    } else if !wroteToStaging {
      _ = retain(data, at: offset, in: transfer, mandatory: false)
    }
  }

  private func deliverDirectly(_ data: Data, at offset: Int64, in transfer: Transfer) {
    let end = offset + Int64(data.count)
    for request in transfer.pending where !request.isCancelled {
      guard let dataRequest = request.dataRequest,
        request.contentInformationRequest == nil || transfer.contentLength != nil
      else {
        continue
      }
      var cursor = dataRequest.currentOffset
      guard cursor >= offset, cursor < end else {
        continue
      }
      let stop = min(end, cursor + remainingBytes(dataRequest, length: transfer.contentLength))
      while cursor < stop, !request.isCancelled {
        let sliceEnd = min(stop, cursor + Int64(limits.chunkSize))
        let lower = data.startIndex + Int(cursor - offset)
        let upper = data.startIndex + Int(sliceEnd - offset)
        dataRequest.respond(with: data.subdata(in: lower..<upper))
        cursor = sliceEnd
      }
    }
  }

  private func writeToStaging(_ data: Data, at offset: Int64, in transfer: Transfer) -> Bool {
    guard let staging = transfer.staging, !staging.adopting, let length = transfer.contentLength,
      offset < length
    else {
      return false
    }
    let count = Int(min(Int64(data.count), length - offset))
    do {
      try staging.writeHandle.seekCompat(toOffset: UInt64(offset))
      try staging.writeHandle.writeCompat(contentsOf: data.prefix(count))
    } catch {
      // Staging is an optimisation: drop it and keep streaming.
      discardStaging(transfer)
      return false
    }
    staging.coverage.insert(offset..<(offset + Int64(count)))
    if staging.coverage.covers(length) {
      adoptStaging(transfer)
    }
    return true
  }

  private func retain(_ data: Data, at offset: Int64, in transfer: Transfer, mandatory: Bool) -> Bool {
    let keep = transfer.pending.compactMap { $0.dataRequest?.currentOffset }
    let cap = limits.perResourceBytes
    if !mandatory, transfer.buffer.byteCount + data.count > cap {
      budget.releaseMemory(transfer.buffer.trim(toFit: max(0, cap - data.count), keeping: keep))
    }
    guard transfer.buffer.byteCount + data.count <= cap else {
      return false
    }
    if !budget.reserveMemory(data.count) {
      trimIdleBuffers(except: transfer)
      guard budget.reserveMemory(data.count) else {
        return false
      }
    }
    let added = transfer.buffer.insert(data, at: offset)
    budget.releaseMemory(data.count - added)
    return true
  }

  /// Under global pressure, idle transfers give up their memory first.
  private func trimIdleBuffers(except active: Transfer) {
    for transfer in transfers.values where transfer !== active && transfer.pending.isEmpty {
      budget.releaseMemory(transfer.buffer.removeAll())
    }
  }

  /// Once the length is known, reserves cache capacity for small complete
  /// files and moves already retained bytes into the staging file.
  fileprivate func prepareStaging(_ transfer: Transfer) {
    guard transfer.staging == nil, transfer.cached == nil, !transfer.stagingDeclined,
      let client = transfer.client, client.enabled, let length = transfer.contentLength, length > 0
    else {
      return
    }
    guard let reservation = cache.reserve(bytes: length, identity: transfer.identity, client: client),
      let writeHandle = try? FileHandle(forWritingTo: reservation.url),
      let readHandle = try? FileHandle(forReadingFrom: reservation.url)
    else {
      transfer.stagingDeclined = true
      return
    }
    transfer.staging = Staging(reservation: reservation, writeHandle: writeHandle, readHandle: readHandle)
    let segments = transfer.buffer.segments
    budget.releaseMemory(transfer.buffer.removeAll())
    for segment in segments where transfer.staging != nil {
      if !writeToStaging(segment.data, at: segment.offset, in: transfer) {
        _ = retain(segment.data, at: segment.offset, in: transfer, mandatory: false)
      }
    }
  }

  private func discardStaging(_ transfer: Transfer) {
    guard let staging = transfer.staging else {
      return
    }
    try? staging.writeHandle.closeCompat()
    try? staging.readHandle.closeCompat()
    cache.cancel(staging.reservation)
    transfer.staging = nil
    transfer.stagingDeclined = true
  }

  /// Adopts a fully covered staging file. Reads continue from the open
  /// handle; the adopted entry stays pinned until the transfer closes.
  private func adoptStaging(_ transfer: Transfer) {
    guard let staging = transfer.staging, !staging.adopting else {
      return
    }
    staging.adopting = true
    try? staging.writeHandle.closeCompat()
    budget.releaseMemory(transfer.buffer.removeAll())
    let cache = self.cache
    cache.adopt(staging.reservation, contentType: transfer.contentType) { [weak self] pin in
      guard let pin else {
        return
      }
      guard let self else {
        cache.unpin(pin)
        return
      }
      self.queue.async {
        if transfer.closed || transfer.staging !== staging {
          cache.unpin(pin)
        } else {
          transfer.staging = nil
          transfer.cached = (pin, staging.readHandle)
        }
      }
    }
  }
}

// MARK: - URLSessionDataDelegate

extension CachingResourceLoader: URLSessionDataDelegate {
  private enum ResponseOutcome {
    case stream
    case endOfResource
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let transfer = transfersByTask[task.taskIdentifier],
      let destination = request.url, let previous = task.currentRequest?.url ?? task.originalRequest?.url
    else {
      completionHandler(nil)
      return
    }
    // Never change protocol across a redirect; a downgrade would expose the
    // request and an upgrade is equally unexpected for signed media URLs.
    guard destination.scheme?.lowercased() == previous.scheme?.lowercased() else {
      completionHandler(nil)
      return
    }
    var redirected = request
    transfer.policy.apply(to: &redirected)
    completionHandler(redirected)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let transfer = transfersByTask[dataTask.taskIdentifier], let fetch = transfer.fetch,
      fetch.task === dataTask
    else {
      completionHandler(.cancel)
      return
    }
    do {
      switch try accept(response, for: fetch, in: transfer) {
      case .stream:
        fetch.responded = true
        completionHandler(.allow)
      case .endOfResource:
        completionHandler(.cancel)
        transfersByTask.removeValue(forKey: dataTask.taskIdentifier)
        transfer.fetch = nil
        budget.releaseTransfer()
      }
      prepareStaging(transfer)
      pump(transfer)
    } catch {
      completionHandler(.cancel)
      fail(transfer, error)
    }
  }

  private func accept(_ response: URLResponse, for fetch: Fetch, in transfer: Transfer) throws -> ResponseOutcome {
    let http = response as? HTTPURLResponse
    let status = http?.statusCode ?? 200
    let validator = http?.value(forHTTPHeaderField: "ETag") ?? http?.value(forHTTPHeaderField: "Last-Modified")
    if let validator, let known = transfer.validator, validator != known {
      throw Self.error(.representationChanged, "Media changed on the server during playback.")
    }
    switch status {
    case 206:
      guard let range = Self.parseContentRange(http?.value(forHTTPHeaderField: "Content-Range")),
        let start = range.start, let end = range.end, start == fetch.start,
        fetch.requestedEnd.map({ end <= $0 }) ?? true
      else {
        throw Self.error(.protocolViolation, "Media server returned an invalid Content-Range.")
      }
      if let total = range.total {
        try setLength(total, of: transfer)
      } else if let requestedEnd = fetch.requestedEnd, end < requestedEnd {
        // A short range with unknown total ends at EOF.
        try setLength(end + 1, of: transfer)
      }
      transfer.rangesSupported = true
      fetch.position = start
      fetch.expectedEnd = end + 1
    case 200:
      let total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
      if let total {
        try setLength(total, of: transfer)
      }
      let wholeRequested = fetch.start == 0 && (fetch.requestedEnd == nil || (total.map { fetch.requestedEnd! >= $0 - 1 } ?? false))
      if fetch.requestedEnd != nil, !wholeRequested {
        transfer.rangesSupported = false
      }
      fetch.position = 0
      fetch.discardUntil = fetch.start
      fetch.expectedEnd = total
      fetch.sequential = true
    case 416:
      guard let total = Self.parseContentRange(http?.value(forHTTPHeaderField: "Content-Range"))?.total,
        fetch.start >= total
      else {
        throw Self.error(.protocolViolation, "Media server rejected a range inside the resource.")
      }
      try setLength(total, of: transfer)
      return .endOfResource
    default:
      throw Self.httpError(statusCode: status)
    }
    if transfer.validator == nil {
      transfer.validator = validator
    }
    if transfer.contentType == nil {
      transfer.contentType = Self.contentType(forMimeType: response.mimeType)
    }
    return .stream
  }

  private func setLength(_ length: Int64, of transfer: Transfer) throws {
    if let known = transfer.contentLength, known != length {
      throw Self.error(.representationChanged, "Media length changed on the server during playback.")
    }
    transfer.contentLength = length
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let transfer = transfersByTask[dataTask.taskIdentifier], let fetch = transfer.fetch,
      fetch.task === dataTask, fetch.responded
    else {
      return
    }
    var offset = fetch.position
    fetch.position += Int64(data.count)
    var payload = data
    if offset < fetch.discardUntil {
      let skip = Int(min(Int64(payload.count), fetch.discardUntil - offset))
      payload = payload.subdata(in: (payload.startIndex + skip)..<payload.endIndex)
      offset += Int64(skip)
    }
    if let end = fetch.expectedEnd, fetch.position > end {
      fail(transfer, Self.error(.protocolViolation, "Media response exceeded its declared length."))
      return
    }
    if !payload.isEmpty {
      receive(payload, at: offset, in: transfer)
    }
    guard !transfer.closed else {
      return
    }
    pump(transfer)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let transfer = transfersByTask.removeValue(forKey: task.taskIdentifier),
      let fetch = transfer.fetch, fetch.task === task
    else {
      return
    }
    transfer.fetch = nil
    budget.releaseTransfer()
    if let error {
      fail(transfer, error)
      return
    }
    if let end = fetch.expectedEnd, fetch.position < end {
      fail(transfer, Self.error(.cacheIO, "Media response ended before all bytes arrived."))
      return
    }
    if fetch.expectedEnd == nil, fetch.sequential {
      do {
        try setLength(fetch.position, of: transfer)
      } catch {
        fail(transfer, error)
        return
      }
      prepareStaging(transfer)
    }
    pump(transfer)
  }
}
