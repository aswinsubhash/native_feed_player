import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Loads and caches progressive media through a custom URL scheme.
///
/// Concurrent requests for one request identity share a sequential download.
final class CachingResourceLoader: NSObject {
  static let scheme = "nfpcache"

  /// Upper bound on bytes handed to a single `respond(with:)` call so open
  /// ended requests never materialise a whole cached file in memory.
  static let chunkSize = 512 * 1024

  private struct RequestContext {
    let headers: [String: String]
  }

  /// Wraps a remote URL so AVFoundation routes it through this delegate.
  /// The opaque identity in the scheme prevents assets with different request
  /// credentials from sharing loader or disk state.
  static func interceptURL(
    for uri: String,
    headers: [String: String] = [:],
    cacheKey: String? = nil
  ) -> URL? {
    let identity = MediaCacheIdentity.make(uri: uri, headers: headers, cacheKey: cacheKey)
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

  /// Partial responses cannot be adopted until the loader stores ranges at
  /// their declared Content-Range offsets.
  static func isCacheableResponse(_ statusCode: Int) -> Bool {
    isSuccessfulHTTPStatus(statusCode) && statusCode != 206
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

  /// Bytes to serve in the next chunk of a cached-file request, or 0 when the
  /// request is already satisfied. Pure so the boundary cases are unit-testable.
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

  fileprivate final class Download: NSObject {
    let identity: String
    let handle: FileHandle
    let temporaryURL: URL
    var task: URLSessionDataTask?
    var contentLength: Int64 = 0
    var contentType: String?
    var bytesWritten: Int64 = 0
    var receivedSuccessfulResponse = false
    var finished = false
    var failure: Error?
    var pending: [AVAssetResourceLoadingRequest] = []
    /// Queue-confined read handle reused across pending-request slices; the
    /// write handle stays positioned at the end of the file.
    var readHandle: FileHandle?

    init(identity: String, temporaryURL: URL, handle: FileHandle) {
      self.identity = identity
      self.temporaryURL = temporaryURL
      self.handle = handle
    }

    func closeReadHandle() {
      if let readHandle {
        try? readHandle.closeCompat()
      }
      readHandle = nil
    }
  }

  private let queue = DispatchQueue(label: "native_feed_player.resourceloader")
  private let sessionConfiguration: URLSessionConfiguration
  private lazy var session: URLSession = {
    URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
  }()

  private var downloadsByIdentity: [String: Download] = [:]
  private var downloadsByTask: [Int: Download] = [:]
  private var contextsByIdentity: [String: RequestContext] = [:]
  var onFailure: ((String, Error) -> Void)?

  init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
    sessionConfiguration.urlCache = nil
    sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.sessionConfiguration = sessionConfiguration
    super.init()
  }

  /// Registers the short-lived request context before AVFoundation can ask the
  /// resource loader for bytes.
  func prepareURL(
    for uri: String,
    headers: [String: String],
    cacheKey: String? = nil
  ) -> URL? {
    guard let intercepted = CachingResourceLoader.interceptURL(
      for: uri,
      headers: headers,
      cacheKey: cacheKey
    ),
      let identity = CachingResourceLoader.identity(from: intercepted)
    else {
      return nil
    }
    let context = RequestContext(headers: MediaCacheIdentity.normalizedHeaders(headers))
    queue.sync {
      contextsByIdentity[identity] = context
    }
    return intercepted
  }

  func cancelAll(completion: (() -> Void)? = nil) {
    queue.async {
      let cancellation = Self.cancellationError()
      for download in Array(self.downloadsByIdentity.values) {
        self.failAndClean(download, error: cancellation, cancelTask: true)
      }
      self.downloadsByIdentity.removeAll()
      self.downloadsByTask.removeAll()
      self.contextsByIdentity.removeAll()
      completion?()
    }
  }

  func cancel(identities: Set<String>, completion: @escaping () -> Void) {
    queue.async {
      let cancellation = Self.cancellationError()
      for identity in identities {
        if let download = self.downloadsByIdentity[identity] {
          self.failAndClean(download, error: cancellation, cancelTask: true)
        }
        self.contextsByIdentity.removeValue(forKey: identity)
      }
      completion()
    }
  }

  /// Breaks URLSession's delegate retention during manager teardown.
  func shutdown() {
    queue.sync {
      let cancellation = Self.cancellationError()
      for download in Array(downloadsByIdentity.values) {
        failAndClean(download, error: cancellation, cancelTask: true)
      }
      downloadsByIdentity.removeAll()
      downloadsByTask.removeAll()
      contextsByIdentity.removeAll()
    }
    session.invalidateAndCancel()
  }

  deinit {
    session.invalidateAndCancel()
  }

  private static func interceptedParts(from interceptedScheme: String?) -> (
    scheme: String?, identity: String?
  ) {
    guard let interceptedScheme, interceptedScheme.hasPrefix("\(scheme)-") else {
      return (nil, nil)
    }
    let remainder = String(interceptedScheme.dropFirst(scheme.count + 1))
    guard let separator = remainder.lastIndex(of: "-") else {
      // Accept the old URL shape only to restore a URL. It has no v2 identity
      // and therefore can never address a cached entry.
      return (remainder, nil)
    }
    let identity = String(remainder[remainder.index(after: separator)...])
    let originalScheme = String(remainder[..<separator])
    guard identity.count == 64, identity.allSatisfy({ $0.isHexDigit }) else {
      return (remainder, nil)
    }
    return (originalScheme, identity.lowercased())
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
      // Serve complete entries from disk.
      if let cached = MediaDiskCache.shared.cachedFile(forIdentity: identity) {
        self.serveFromFile(loadingRequest, cached: cached)
        self.contextsByIdentity.removeValue(forKey: identity)
        return
      }

      let download = self.downloadsByIdentity[identity]
        ?? self.startDownload(identity: identity, originalURL: originalURL)
      guard let download else {
        loadingRequest.finishLoading(with: CachingResourceLoader.cacheError())
        return
      }
      download.pending.append(loadingRequest)
      self.servePending(download)
    }
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    queue.async {
      for download in Array(self.downloadsByIdentity.values) where
        download.pending.contains(where: { $0 === loadingRequest })
      {
        // AVFoundation already owns the cancelled request's terminal state, so
        // do not invoke it again. Cancel and clean an otherwise unused task.
        download.pending.removeAll { $0 === loadingRequest }
        if download.pending.isEmpty {
          self.failAndClean(
            download,
            error: CachingResourceLoader.cancellationError(),
            cancelTask: true
          )
        }
      }
    }
  }

  private func serveFromFile(
    _ request: AVAssetResourceLoadingRequest,
    cached: (url: URL, contentType: String?, byteCount: Int64)
  ) {
    if let info = request.contentInformationRequest {
      info.contentType = CachingResourceLoader.normalizedContentType(cached.contentType)
        ?? AVFileType.mp4.rawValue
      info.contentLength = cached.byteCount
      info.isByteRangeAccessSupported = true
    }
    guard let dataRequest = request.dataRequest else {
      if !request.isCancelled {
        request.finishLoading()
      }
      return
    }
    do {
      let handle = try FileHandle(forReadingFrom: cached.url)
      defer { try? handle.closeCompat() }
      try handle.seekCompat(toOffset: UInt64(max(0, dataRequest.currentOffset)))
      // Serve the requested range in bounded chunks on this one request:
      // respond() accumulates until finishLoading(), so chunking bounds the
      // live allocation while still satisfying the full range — finishing
      // after a partial response would risk stalls for open-ended requests.
      let openEnded = dataRequest.requestsAllDataToEndOfResource
      while !request.isCancelled {
        let alreadyServed = Int64(dataRequest.currentOffset - dataRequest.requestedOffset)
        let plan = CachingResourceLoader.chunkPlan(
          requestedLength: Int64(dataRequest.requestedLength),
          alreadyServed: alreadyServed,
          currentOffset: dataRequest.currentOffset,
          byteCount: cached.byteCount,
          requestsAllDataToEndOfResource: openEnded
        )
        guard plan > 0 else {
          break
        }
        guard let data = try handle.readCompat(upToCount: Int(plan)), !data.isEmpty else {
          break
        }
        guard !request.isCancelled else {
          break
        }
        dataRequest.respond(with: data)
        let served = Int64(dataRequest.currentOffset - dataRequest.requestedOffset)
        if (!openEnded && served >= Int64(dataRequest.requestedLength))
          || (openEnded && dataRequest.currentOffset >= cached.byteCount)
        {
          break
        }
      }
      if !request.isCancelled {
        let served = Int64(dataRequest.currentOffset - dataRequest.requestedOffset)
        let complete = openEnded
          ? dataRequest.currentOffset >= cached.byteCount
          : served >= Int64(dataRequest.requestedLength)
        if complete {
          request.finishLoading()
        } else {
          request.finishLoading(
            with: CachingResourceLoader.cacheError("Cached media ended before the requested range.")
          )
        }
      }
    } catch {
      if !request.isCancelled {
        request.finishLoading(with: error)
      }
    }
  }
}

// MARK: - Download coordination

extension CachingResourceLoader {
  private static func cacheError(_ description: String = "Unable to open a cache file for writing.") -> NSError {
    NSError(
      domain: "native_feed_player.cache",
      code: -1,
      userInfo: [NSLocalizedDescriptionKey: description]
    )
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

  private func startDownload(identity: String, originalURL: URL) -> Download? {
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nfp-\(identity)-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: temporaryURL) else {
      try? FileManager.default.removeItem(at: temporaryURL)
      contextsByIdentity.removeValue(forKey: identity)
      return nil
    }

    let download = Download(identity: identity, temporaryURL: temporaryURL, handle: handle)
    var request = URLRequest(url: originalURL)
    for (field, value) in contextsByIdentity[identity]?.headers ?? [:]
    where field.lowercased() != "range" {
      request.setValue(value, forHTTPHeaderField: field)
    }
    let task = session.dataTask(with: request)
    download.task = task
    downloadsByIdentity[identity] = download
    downloadsByTask[task.taskIdentifier] = download
    task.resume()
    return download
  }

  /// Serves pending requests from downloaded bytes.
  fileprivate func servePending(_ download: Download) {
    var stillPending: [AVAssetResourceLoadingRequest] = []

    for request in download.pending {
      if request.isCancelled {
        continue
      }
      if download.finished, let failure = download.failure {
        request.finishLoading(with: failure)
        continue
      }

      if let info = request.contentInformationRequest {
        // Wait for validated response headers before serving content metadata.
        guard download.receivedSuccessfulResponse || download.finished else {
          stillPending.append(request)
          continue
        }
        info.contentType = download.contentType ?? AVFileType.mp4.rawValue
        if download.contentLength > 0 {
          info.contentLength = download.contentLength
        } else if download.finished {
          info.contentLength = download.bytesWritten
        }
        info.isByteRangeAccessSupported = true
      }

      guard let dataRequest = request.dataRequest else {
        if download.contentLength > 0 || download.finished {
          request.finishLoading()
        } else {
          stillPending.append(request)
        }
        continue
      }

      let offset = dataRequest.currentOffset
      let openEnded = dataRequest.requestsAllDataToEndOfResource
      let available = download.bytesWritten - offset
      if available <= 0 {
        if download.finished, openEnded, offset >= download.bytesWritten {
          request.finishLoading()
        } else if download.finished {
          request.finishLoading(
            with: download.failure
              ?? CachingResourceLoader.cacheError("Media ended before the requested range.")
          )
        } else {
          stillPending.append(request)
        }
        continue
      }

      let outstanding = openEnded
        ? Int64.max
        : Int64(dataRequest.requestedLength) - (offset - dataRequest.requestedOffset)
      // Cap each response so a completed download is never served as one
      // giant allocation; the request stays pending and is re-served from
      // the new offset until it is satisfied.
      let length = Int(min(Int64(CachingResourceLoader.chunkSize), available, outstanding))
      if length > 0, let data = readPrefix(download, offset: offset, length: length) {
        dataRequest.respond(with: data)
      }

      let served = dataRequest.currentOffset - dataRequest.requestedOffset
      let contentInformationReady = request.contentInformationRequest == nil
        || download.contentLength > 0
        || download.finished
      if !openEnded, served >= Int64(dataRequest.requestedLength), contentInformationReady {
        request.finishLoading()
      } else if download.finished, openEnded, dataRequest.currentOffset >= download.bytesWritten {
        request.finishLoading()
      } else if download.finished {
        request.finishLoading(
          with: download.failure
            ?? CachingResourceLoader.cacheError("Media ended before the requested range.")
        )
      } else {
        stillPending.append(request)
      }
    }

    download.pending = stillPending
  }

  private func readPrefix(_ download: Download, offset: Int64, length: Int) -> Data? {
    if download.readHandle == nil {
      guard let handle = try? FileHandle(forReadingFrom: download.temporaryURL) else {
        return nil
      }
      download.readHandle = handle
    }
    guard let handle = download.readHandle else {
      return nil
    }
    do {
      try handle.seekCompat(toOffset: UInt64(max(0, offset)))
      return try handle.readCompat(upToCount: length)
    } catch {
      download.closeReadHandle()
      return nil
    }
  }

  private func failAndClean(_ download: Download, error: Error, cancelTask: Bool) {
    guard !download.finished else {
      return
    }
    download.finished = true
    download.failure = download.failure ?? error
    if cancelTask {
      download.task?.cancel()
    }
    try? download.handle.closeCompat()
    servePending(download)
    download.closeReadHandle()
    // Defensive: every non-cancelled pending request must reach a terminal state.
    for request in download.pending where !request.isCancelled {
      request.finishLoading(with: download.failure)
    }
    download.pending.removeAll()
    let failure = download.failure as NSError?
    if failure?.domain != NSURLErrorDomain || failure?.code != NSURLErrorCancelled {
      onFailure?(download.identity, download.failure ?? error)
    }
    if let task = download.task {
      downloadsByTask.removeValue(forKey: task.taskIdentifier)
    }
    downloadsByIdentity.removeValue(forKey: download.identity)
    contextsByIdentity.removeValue(forKey: download.identity)
    try? FileManager.default.removeItem(at: download.temporaryURL)
  }
}

// MARK: - URLSessionDataDelegate

extension CachingResourceLoader: URLSessionDataDelegate {
  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    queue.async {
      guard let download = self.downloadsByTask[dataTask.taskIdentifier] else {
        completionHandler(.cancel)
        return
      }
      if let http = response as? HTTPURLResponse,
        !CachingResourceLoader.isCacheableResponse(http.statusCode)
      {
        self.failAndClean(
          download,
          error: CachingResourceLoader.httpError(statusCode: http.statusCode),
          cancelTask: true
        )
        completionHandler(.cancel)
        return
      }
      download.receivedSuccessfulResponse = true
      download.contentLength = response.expectedContentLength > 0
        ? response.expectedContentLength
        : 0
      download.contentType = CachingResourceLoader.contentType(forMimeType: response.mimeType)
      self.servePending(download)
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    queue.async {
      guard let download = self.downloadsByTask[dataTask.taskIdentifier],
        !download.finished,
        download.receivedSuccessfulResponse
      else {
        return
      }
      do {
        try download.handle.seekToEndCompat()
        try download.handle.writeCompat(contentsOf: data)
        download.bytesWritten += Int64(data.count)
        self.servePending(download)
      } catch {
        download.failure = error
        self.failAndClean(download, error: error, cancelTask: true)
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    queue.async {
      guard let download = self.downloadsByTask.removeValue(forKey: task.taskIdentifier) else {
        return
      }
      download.finished = true
      download.failure = download.failure ?? error
      try? download.handle.closeCompat()

      let complete = download.failure == nil
        && download.receivedSuccessfulResponse
        && download.bytesWritten > 0
        && (download.contentLength == 0 || download.bytesWritten >= download.contentLength)
      if complete, download.contentLength == 0 {
        download.contentLength = download.bytesWritten
      }
      if !complete, download.failure == nil {
        download.failure = CachingResourceLoader.cacheError("Media response ended before all bytes arrived.")
      }
      if !complete, let failure = download.failure as NSError?,
        failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled
      {
        self.onFailure?(download.identity, failure)
      }
      self.servePending(download)
      download.closeReadHandle()
      for request in download.pending where !request.isCancelled {
        request.finishLoading(with: download.failure)
      }
      download.pending.removeAll()
      self.downloadsByIdentity.removeValue(forKey: download.identity)

      if complete {
        MediaDiskCache.shared.store(
          temporaryFile: download.temporaryURL,
          identity: download.identity,
          contentType: download.contentType
        ) { [weak self] in
          self?.queue.async {
            // A retry may have installed a fresh context while adoption ran.
            if self?.downloadsByIdentity[download.identity] == nil {
              self?.contextsByIdentity.removeValue(forKey: download.identity)
            }
          }
        }
      } else {
        self.contextsByIdentity.removeValue(forKey: download.identity)
        try? FileManager.default.removeItem(at: download.temporaryURL)
      }
    }
  }
}
