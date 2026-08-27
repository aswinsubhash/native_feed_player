import CryptoKit
import Foundation

/// On-disk store for fully downloaded media, with an LRU budget.
///
/// Entries are whole files rather than sparse byte ranges. Feed clips are
/// short and played start to finish, so a per-file model gives the same hit
/// rate as range bookkeeping for a fraction of the complexity and none of the
/// partial-range correctness hazards.
final class MediaDiskCache {
  private struct Entry: Codable {
    let key: String
    let uri: String
    let contentType: String?
    let byteCount: Int64
    var lastAccess: TimeInterval
  }

  static let shared = MediaDiskCache()

  private let queue = DispatchQueue(label: "native_feed_player.cache", attributes: .concurrent)
  private let fileManager = FileManager.default

  private var entries: [String: Entry] = [:]
  private var maxBytes: Int64 = 0
  private var enabled = false

  private lazy var rootURL: URL = {
    let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("native_feed_player", isDirectory: true)
  }()

  private var indexURL: URL {
    rootURL.appendingPathComponent("index.json")
  }

  // MARK: - Configuration

  func configure(enabled: Bool, maxBytes: Int64) {
    queue.sync(flags: .barrier) {
      self.enabled = enabled
      self.maxBytes = maxBytes
      guard enabled else {
        return
      }
      try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
      loadIndexLocked()
      enforceBudgetLocked()
    }
  }

  var isEnabled: Bool {
    queue.sync { enabled }
  }

  // MARK: - Lookup

  static func key(for uri: String) -> String {
    let digest = SHA256.hash(data: Data(uri.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  func fileURL(forKey key: String) -> URL {
    rootURL.appendingPathComponent(key)
  }

  /// Returns the local file for a fully cached URI, refreshing its LRU stamp.
  func cachedFile(for uri: String) -> (url: URL, contentType: String?, byteCount: Int64)? {
    let key = MediaDiskCache.key(for: uri)
    return queue.sync(flags: .barrier) { () -> (URL, String?, Int64)? in
      guard enabled, var entry = entries[key] else {
        return nil
      }
      let url = fileURL(forKey: key)
      guard fileManager.fileExists(atPath: url.path) else {
        entries.removeValue(forKey: key)
        return nil
      }
      entry.lastAccess = Date().timeIntervalSince1970
      entries[key] = entry
      saveIndexLocked()
      return (url, entry.contentType, entry.byteCount)
    }
  }

  func cachedBytes(for uri: String) -> Int64 {
    let key = MediaDiskCache.key(for: uri)
    return queue.sync { entries[key]?.byteCount ?? 0 }
  }

  func usageBytes() -> Int64 {
    queue.sync { entries.values.reduce(0) { $0 + $1.byteCount } }
  }

  // MARK: - Mutation

  /// Adopts a completed download into the cache.
  func store(temporaryFile: URL, uri: String, contentType: String?) {
    guard isEnabled else {
      try? fileManager.removeItem(at: temporaryFile)
      return
    }
    let key = MediaDiskCache.key(for: uri)
    queue.sync(flags: .barrier) {
      let destination = fileURL(forKey: key)
      try? fileManager.removeItem(at: destination)
      do {
        try fileManager.moveItem(at: temporaryFile, to: destination)
      } catch {
        try? fileManager.removeItem(at: temporaryFile)
        return
      }
      let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64)
        ?? 0
      entries[key] = Entry(
        key: key,
        uri: uri,
        contentType: contentType,
        byteCount: size,
        lastAccess: Date().timeIntervalSince1970
      )
      saveIndexLocked()
      enforceBudgetLocked()
    }
  }

  func evict(uri: String) {
    let key = MediaDiskCache.key(for: uri)
    queue.sync(flags: .barrier) {
      removeEntryLocked(key: key)
      saveIndexLocked()
    }
  }

  func evictAll() {
    queue.sync(flags: .barrier) {
      for key in entries.keys {
        try? fileManager.removeItem(at: fileURL(forKey: key))
      }
      entries.removeAll()
      saveIndexLocked()
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
      let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
    else {
      entries = [:]
      return
    }
    // Drop index rows whose file vanished (manual clear, OS cache purge).
    entries = decoded.filter { fileManager.fileExists(atPath: fileURL(forKey: $0.key).path) }
  }

  private func saveIndexLocked() {
    guard let data = try? JSONEncoder().encode(entries) else {
      return
    }
    try? data.write(to: indexURL, options: .atomic)
  }
}
