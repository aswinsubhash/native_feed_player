import AVFoundation
import Foundation

/// Loads and caches progressive media through a custom URL scheme.
///
/// Concurrent requests for one URI share a sequential download.
final class CachingResourceLoader: NSObject {
  static let scheme = "nfpcache"

  /// Wraps a remote URL so AVFoundation routes it through this delegate.
  static func interceptURL(for uri: String) -> URL? {
    guard var components = URLComponents(string: uri), let originalScheme = components.scheme
    else {
      return nil
    }
    components.scheme = "\(scheme)-\(originalScheme)"
    return components.url
  }

  /// Restores the real URL from an intercepted one.
  static func originalURL(from url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let intercepted = components.scheme,
      intercepted.hasPrefix("\(scheme)-")
    else {
      return nil
    }
    components.scheme = String(intercepted.dropFirst(scheme.count + 1))
    return components.url
  }

  fileprivate final class Download: NSObject {
    let uri: String
    let handle: FileHandle
    let temporaryURL: URL
    var task: URLSessionDataTask?
    var contentLength: Int64 = 0
    var contentType: String?
    var bytesWritten: Int64 = 0
    var finished = false
    var failure: Error?
    var pending: [AVAssetResourceLoadingRequest] = []

    init(uri: String, temporaryURL: URL, handle: FileHandle) {
      self.uri = uri
      self.temporaryURL = temporaryURL
      self.handle = handle
    }
  }

  private let queue = DispatchQueue(label: "native_feed_player.resourceloader")
  private lazy var session: URLSession = {
    URLSession(configuration: .default, delegate: self, delegateQueue: nil)
  }()

  private var downloadsByUri: [String: Download] = [:]
  private var downloadsByTask: [Int: Download] = [:]
  private var headersByUri: [String: [String: String]] = [:]

  func setHeaders(_ headers: [String: String], for uri: String) {
    queue.async { self.headersByUri[uri] = headers }
  }

  func cancelAll() {
    queue.async {
      for (_, download) in self.downloadsByUri {
        download.task?.cancel()
        try? download.handle.closeCompat()
        try? FileManager.default.removeItem(at: download.temporaryURL)
      }
      self.downloadsByUri.removeAll()
      self.downloadsByTask.removeAll()
    }
  }
}

// MARK: - AVAssetResourceLoaderDelegate

extension CachingResourceLoader: AVAssetResourceLoaderDelegate {
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard let interceptedURL = loadingRequest.request.url,
      let originalURL = CachingResourceLoader.originalURL(from: interceptedURL)
    else {
      return false
    }
    let uri = originalURL.absoluteString

    // Serve complete entries from disk.
    if let cached = MediaDiskCache.shared.cachedFile(for: uri) {
      serveFromFile(loadingRequest, cached: cached)
      return true
    }

    queue.async {
      let download = self.downloadsByUri[uri]
        ?? self.startDownload(uri: uri, originalURL: originalURL)
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
      for (_, download) in self.downloadsByUri {
        download.pending.removeAll { $0 === loadingRequest }
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
  private static func cacheError() -> NSError {
    NSError(
      domain: "native_feed_player.cache",
      code: -1,
      userInfo: [NSLocalizedDescriptionKey: "Unable to open a cache file for writing."]
    )
  }

  private func startDownload(uri: String, originalURL: URL) -> Download? {
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nfp-\(MediaDiskCache.key(for: uri))")
    FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: temporaryURL) else {
      return nil
    }

    let download = Download(uri: uri, temporaryURL: temporaryURL, handle: handle)
    var request = URLRequest(url: originalURL)
    for (field, value) in headersByUri[uri] ?? [:] {
      request.setValue(value, forHTTPHeaderField: field)
    }
    let task = session.dataTask(with: request)
    download.task = task
    downloadsByUri[uri] = download
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

      if let info = request.contentInformationRequest {
        // Wait for response headers before serving content metadata.
        guard download.contentLength > 0 || download.finished else {
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
      if let download = self.downloadsByTask[dataTask.taskIdentifier] {
        download.contentLength = response.expectedContentLength > 0
          ? response.expectedContentLength
          : 0
        download.contentType = response.mimeType
        self.servePending(download)
      }
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    queue.async {
      guard let download = self.downloadsByTask[dataTask.taskIdentifier] else {
        return
      }
      do {
        try download.handle.seekToEndCompat()
        try download.handle.writeCompat(contentsOf: data)
        download.bytesWritten += Int64(data.count)
      } catch {
        download.failure = error
      }
      self.servePending(download)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    queue.async {
      guard let download = self.downloadsByTask.removeValue(forKey: task.taskIdentifier) else {
        return
      }
      download.finished = true
      download.failure = error
      try? download.handle.closeCompat()
      self.servePending(download)
      self.downloadsByUri.removeValue(forKey: download.uri)

      // Cache only complete response bodies.
      let complete = error == nil
        && download.bytesWritten > 0
        && (download.contentLength == 0 || download.bytesWritten >= download.contentLength)
      if complete {
        MediaDiskCache.shared.store(
          temporaryFile: download.temporaryURL,
          uri: download.uri,
          contentType: download.contentType
        )
      } else {
        try? FileManager.default.removeItem(at: download.temporaryURL)
      }
    }
  }
}
