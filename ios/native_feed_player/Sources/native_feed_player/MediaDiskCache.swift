import CryptoKit
import Foundation

/// Builds an opaque, credential-safe identity for a media request.
///
/// The digest includes the complete URI and normalized HTTP headers, but only
/// the SHA-256 result is used as a loader key, file name, or persisted value.
enum MediaCacheIdentity {
  static let schemaVersion = "native-feed-player-cache-v2"

  static func make(uri: String, headers: [String: String], cacheKey: String? = nil) -> String {
    var material = Data()
    append(schemaVersion, to: &material)
    // A caller-supplied cacheKey replaces the URI so signed or expiring URLs
    // share one entry; headers stay in the digest either way.
    let identity: String
    if let key = cacheKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
      identity = key
    } else {
      identity = uri
    }
    append(identity, to: &material)
    for (name, value) in canonicalHeaders(headers) {
      append(name, to: &material)
      append(value, to: &material)
    }
    let digest = SHA256.hash(data: material)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Header names are case-insensitive. Sending the normalized headers and
  /// hashing the same representation prevents differently-cased credentials
  /// from sharing a cache entry.
  static func normalizedHeaders(_ headers: [String: String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: canonicalHeaders(headers))
  }

  private static func canonicalHeaders(_ headers: [String: String]) -> [(String, String)] {
    var normalized: [String: String] = [:]
    // Resolve duplicate differently-cased names deterministically before
    // sorting. Such duplicates cannot both be represented by URLRequest.
    for (name, value) in headers.sorted(by: {
      let left = $0.key.lowercased()
      let right = $1.key.lowercased()
      return left == right ? $0.key < $1.key : left < right
    }) {
      let canonicalName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !canonicalName.isEmpty else {
        continue
      }
      normalized[canonicalName] = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return normalized.sorted { $0.key < $1.key }
  }

  private static func append(_ value: String, to data: inout Data) {
    let bytes = Data(value.utf8)
    var length = UInt64(bytes.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(bytes)
  }
}

/// LRU disk cache for complete media files.
final class MediaDiskCache {
  private struct Entry: Codable {
    let key: String
    let contentType: String?
    let byteCount: Int64
    var lastAccess: TimeInterval
  }

  private struct Index: Codable {
    let schemaVersion: Int
    let entries: [String: Entry]
  }

  static let shared = MediaDiskCache()

  private static let indexSchemaVersion = 2

  private let queue = DispatchQueue(label: "native_feed_player.cache", attributes: .concurrent)
  private let fileManager = FileManager.default
  /// Guards the configuration so `isEnabled` never blocks on the cache queue
  /// while a configure barrier is queued behind pending disk work.
  private let stateLock = NSLock()
  private var enabledState = false
  private var maxBytesState: Int64 = 0

  private var entries: [String: Entry] = [:]
  private var maxBytes: Int64 {
    get { stateLock.withLock { maxBytesState } }
    set { stateLock.withLock { maxBytesState = newValue } }
  }
  private var enabled: Bool {
    get { stateLock.withLock { enabledState } }
    set { stateLock.withLock { enabledState = newValue } }
  }
  /// Pending LRU-stamp writes, coalesced onto one delayed barrier.
  private var indexWritePending = false
  private var indexWriteScheduled = false

  private lazy var rootURL: URL = {
    let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("native_feed_player", isDirectory: true)
  }()

  private var indexURL: URL {
    rootURL.appendingPathComponent("index.json")
  }

  // MARK: - Configuration

  /// Configures the cache without blocking the caller. `maxBytes` is only
  /// read inside barriers, so it must be visible before the load barrier
  /// runs; `enabled` flips last so any lookup submitted after the caller
  /// observes `isEnabled == true` is ordered behind a fully loaded index.
  func configure(enabled: Bool, maxBytes: Int64) {
    self.maxBytes = maxBytes
    guard enabled else {
      self.enabled = false
      return
    }
    queue.async(flags: .barrier) {
      try? self.fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
      self.loadIndexLocked()
      self.enforceBudgetLocked()
    }
    self.enabled = true
  }

  /// Blocks until all queued cache work (including a pending configure) has
  /// finished. Testing hook only.
  func waitForPendingWorkForTesting() {
    queue.sync(flags: .barrier) {}
  }

  var isEnabled: Bool {
    stateLock.withLock { enabledState }
  }

  // MARK: - Lookup

  static func identity(for uri: String, headers: [String: String]) -> String {
    MediaCacheIdentity.make(uri: uri, headers: headers)
  }

  /// Kept as a convenience for headerless requests and unit tests.
  static func key(for uri: String) -> String {
    identity(for: uri, headers: [:])
  }

  func fileURL(forKey key: String) -> URL {
    rootURL.appendingPathComponent(key)
  }

  /// Returns the local file for a fully cached request, refreshing its LRU
  /// stamp asynchronously so the resource-loader queue never waits on a
  /// synchronous index write.
  func cachedFile(forIdentity identity: String) -> (url: URL, contentType: String?, byteCount: Int64)? {
    queue.sync(flags: .barrier) {
      guard enabled, var entry = entries[identity] else {
        return nil
      }
      let url = fileURL(forKey: identity)
      // Verify the on-disk size still matches the index: a truncated file
      // (crash mid-move, external eviction) must not be served with the
      // recorded content length.
      let sizeOnDisk = (try? fileManager.attributesOfItem(atPath: url.path))?[
        .size
      ] as? Int64
      guard sizeOnDisk == entry.byteCount else {
        removeEntryLocked(key: identity)
        saveIndexLocked()
        return nil
      }
      entry.lastAccess = Date().timeIntervalSince1970
      entries[identity] = entry
      scheduleIndexWriteLocked()
      return (url, entry.contentType, entry.byteCount)
    }
  }

  func cachedBytes(forIdentity identity: String, completion: @escaping (Int64) -> Void) {
    queue.async {
      completion(self.entries[identity]?.byteCount ?? 0)
    }
  }

  func usageBytes(completion: @escaping (Int64) -> Void) {
    queue.async {
      completion(self.entries.values.reduce(0) { $0 + $1.byteCount })
    }
  }

  // MARK: - Mutation

  /// Adopts a completed download into the cache. Ownership of the temporary
  /// file transfers to the cache queue immediately.
  func store(
    temporaryFile: URL,
    identity: String,
    contentType: String?,
    completion: (() -> Void)? = nil
  ) {
    queue.async(flags: .barrier) {
      guard self.enabled else {
        try? self.fileManager.removeItem(at: temporaryFile)
        completion?()
        return
      }
      let destination = self.fileURL(forKey: identity)
      try? self.fileManager.removeItem(at: destination)
      do {
        try self.fileManager.moveItem(at: temporaryFile, to: destination)
      } catch {
        try? self.fileManager.removeItem(at: temporaryFile)
        completion?()
        return
      }
      // A failed size lookup must not record a zero-byte entry: the real file
      // would be invisible to the budget and never evicted. Drop the adoption.
      guard let size = try? self.fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64 else {
        try? self.fileManager.removeItem(at: destination)
        completion?()
        return
      }
      self.entries[identity] = Entry(
        key: identity,
        contentType: contentType,
        byteCount: size,
        lastAccess: Date().timeIntervalSince1970
      )
      self.saveIndexLocked()
      self.enforceBudgetLocked()
      completion?()
    }
  }

  func evict(identities: Set<String>, completion: @escaping () -> Void) {
    queue.async(flags: .barrier) {
      for identity in identities {
        self.removeEntryLocked(key: identity)
      }
      self.saveIndexLocked()
      completion()
    }
  }

  func evictAll(completion: @escaping () -> Void) {
    queue.async(flags: .barrier) {
      for key in self.entries.keys {
        try? self.fileManager.removeItem(at: self.fileURL(forKey: key))
      }
      self.entries.removeAll()
      self.saveIndexLocked()
      completion()
    }
  }

  // MARK: - Locked helpers

  private func removeEntryLocked(key: String) {
    try? fileManager.removeItem(at: fileURL(forKey: key))
    entries.removeValue(forKey: key)
  }

  /// Drops least recently used entries until the store fits the budget.
  private func enforceBudgetLocked() {
    guard maxBytes > 0 else {
      return
    }
    var total = entries.values.reduce(Int64(0)) { $0 + $1.byteCount }
    guard total > maxBytes else {
      return
    }
    let ordered = entries.values.sorted { $0.lastAccess < $1.lastAccess }
    for entry in ordered {
      guard total > maxBytes else {
        break
      }
      total -= entry.byteCount
      removeEntryLocked(key: entry.key)
    }
    saveIndexLocked()
  }

  private func loadIndexLocked() {
    guard let data = try? Data(contentsOf: indexURL),
      let index = try? JSONDecoder().decode(Index.self, from: data),
      index.schemaVersion == MediaDiskCache.indexSchemaVersion
    else {
      invalidateLegacySchemaLocked()
      return
    }
    // Discard index entries whose files are missing.
    entries = index.entries.filter { fileManager.fileExists(atPath: fileURL(forKey: $0.key).path) }
    saveIndexLocked()
  }

  /// The previous index persisted raw URIs and keyed files without headers.
  /// Delete it atomically on first v2 configuration so it can never be reused.
  private func invalidateLegacySchemaLocked() {
    if let contents = try? fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: nil
    ) {
      for url in contents {
        try? fileManager.removeItem(at: url)
      }
    }
    entries = [:]
    saveIndexLocked()
  }

  private func saveIndexLocked() {
    let index = Index(schemaVersion: MediaDiskCache.indexSchemaVersion, entries: entries)
    guard let data = try? JSONEncoder().encode(index) else {
      return
    }
    try? data.write(to: indexURL, options: .atomic)
  }

  /// Coalesces LRU-only index rewrites: at most one delayed write is in
  /// flight, so repeated cache hits cost no synchronous disk I/O. Structural
  /// changes (store/evict/configure) call `saveIndexLocked` directly instead.
  private func scheduleIndexWriteLocked() {
    indexWritePending = true
    guard !indexWriteScheduled else {
      return
    }
    indexWriteScheduled = true
    queue.asyncAfter(deadline: .now() + 0.5, flags: .barrier) { [weak self] in
      guard let self else {
        return
      }
      self.indexWriteScheduled = false
      guard self.indexWritePending else {
        return
      }
      self.indexWritePending = false
      self.saveIndexLocked()
    }
  }
}
