import AVFoundation
import Foundation

/// Loads and caches progressive media through a custom URL scheme.
///
/// Concurrent requests for one request identity share a sequential download.
final class CachingResourceLoader: NSObject {
  static let scheme = "nfpcache"

  private struct RequestContext {
    let headers: [String: String]
  }

  /// Wraps a remote URL so AVFoundation routes it through this delegate.
  /// The opaque identity in the scheme prevents assets with different request
  /// credentials from sharing loader or disk state.
  static func interceptURL(for uri: String, headers: [String: String] = [:]) -> URL? {
    let identity = MediaCacheIdentity.make(uri: uri, headers: headers)
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

    init(identity: String, temporaryURL: URL, handle: FileHandle) {
      self.identity = identity
      self.temporaryURL = temporaryURL
      self.handle = handle
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
  func prepareURL(for uri: String, headers: [String: String]) -> URL? {
    guard let intercepted = CachingResourceLoader.interceptURL(for: uri, headers: headers),
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

    // Serve complete entries from disk.
    if let cached = MediaDiskCache.shared.cachedFile(forIdentity: identity) {
      serveFromFile(loadingRequest, cached: cached)
      return true
    }

    queue.async {
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
      info.contentType = cached.contentType ?? AVFileType.mp4.rawValue
      info.contentLength = cached.byteCount
      info.isByteRangeAccessSupported = true
    }
    guard let dataRequest = request.dataRequest else {
      request.finishLoading()
      return
    }
    do {
      let handle = try FileHandle(forReadingFrom: cached.url)
      defer { try? handle.closeCompat() }
      try handle.seekCompat(toOffset: UInt64(max(0, dataRequest.currentOffset)))
      let wanted = dataRequest.requestedLength - Int(
        dataRequest.currentOffset - dataRequest.requestedOffset
      )
      let data = try handle.readCompat(upToCount: max(0, wanted)) ?? Data()
      dataRequest.respond(with: data)
      request.finishLoading()
    } catch {
      request.finishLoading(with: error)
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
    for (field, value) in contextsByIdentity[identity]?.headers ?? [:] {
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
        info.contentLength = download.contentLength
        info.isByteRangeAccessSupported = true
      }

      guard let dataRequest = request.dataRequest else {
        request.finishLoading()
        continue
      }

      let offset = dataRequest.currentOffset
      let available = download.bytesWritten - offset
      if available <= 0 {
        if download.finished {
          request.finishLoading(with: download.failure)
        } else {
          stillPending.append(request)
        }
        continue
      }

      let outstanding = Int64(dataRequest.requestedLength)
        - (offset - dataRequest.requestedOffset)
      let length = Int(min(available, outstanding))
      if length > 0, let data = readPrefix(download, offset: offset, length: length) {
        dataRequest.respond(with: data)
      }

      let served = dataRequest.currentOffset - dataRequest.requestedOffset
      if served >= Int64(dataRequest.requestedLength) {
        request.finishLoading()
      } else if download.finished {
        request.finishLoading(with: download.failure)
      } else {
        stillPending.append(request)
      }
    }

    download.pending = stillPending
  }

  private func readPrefix(_ download: Download, offset: Int64, length: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: download.temporaryURL) else {
      return nil
    }
    defer { try? handle.closeCompat() }
    try? handle.seekCompat(toOffset: UInt64(max(0, offset)))
    return try? handle.readCompat(upToCount: length)
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
        !CachingResourceLoader.isSuccessfulHTTPStatus(http.statusCode)
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
      download.contentType = response.mimeType
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
      if !complete, download.failure == nil {
        download.failure = CachingResourceLoader.cacheError("Media response ended before all bytes arrived.")
      }
      if !complete, let failure = download.failure as NSError?,
        failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled
      {
        self.onFailure?(download.identity, failure)
      }
      self.servePending(download)
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
