import CryptoKit
import Foundation

/// Builds an opaque, credential-safe identity for a media request.
///
/// The digest includes the complete URI and normalized HTTP headers, but only
/// the SHA-256 result is used as a loader key, file name, or persisted value.
enum MediaCacheIdentity {
  static let schemaVersion = "native-feed-player-cache-v2"

  static func make(
    uri: String,
    headers: [String: String],
    cacheKey: String? = nil,
    trustedOrigins: [String] = []
  ) -> String {
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
    let canonical = canonicalHeaders(headers)
    for (name, value) in canonical {
      append(name, to: &material)
      append(value, to: &material)
    }
    // Authenticated bytes are partitioned by the origins allowed to see the
    // credentials, so entries filled under another header policy (including
    // the former unrestricted one) are never reused.
    if !canonical.isEmpty {
      append("origins:v1", to: &material)
      for origin in canonicalOrigins(trustedOrigins) {
        append(origin, to: &material)
      }
    }
    let digest = SHA256.hash(data: material)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func canonicalOrigins(_ origins: [String]) -> [String] {
    Set(origins.map { SourceRequestPolicy.canonicalOrigin($0) ?? $0 }).sorted()
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

/// LRU disk cache for complete media files, shared by every engine.
///
/// Each engine holds a `Client` lease carrying its own policy: a disabled
/// client never reads or writes persistent media, even while another engine
/// uses the store. In-progress downloads reserve capacity before writing, and
/// files being read are pinned, so eviction never leaves unaccounted storage
/// behind.
final class MediaDiskCache {
  /// One engine's lease on the shared store.
  final class Client {
    let enabled: Bool
    let maxBytes: Int64
    fileprivate let id = UUID()
    fileprivate var released = false

    fileprivate init(enabled: Bool, maxBytes: Int64) {
      self.enabled = enabled
      self.maxBytes = maxBytes
    }
  }

  /// Capacity held for one in-progress download, staged at `url`.
  final class Reservation {
    let url: URL
    let bytes: Int64
    let identity: String
    fileprivate let id = UUID()
    fileprivate let clientId: UUID
    fileprivate let epoch: Int
    fileprivate let identityEpoch: Int

    fileprivate init(
      url: URL, bytes: Int64, identity: String, clientId: UUID, epoch: Int, identityEpoch: Int
    ) {
      self.url = url
      self.bytes = bytes
      self.identity = identity
      self.clientId = clientId
      self.epoch = epoch
      self.identityEpoch = identityEpoch
    }
  }

  /// A complete entry held open by readers.
  final class PinnedFile {
    let identity: String
    let byteCount: Int64
    let contentType: String?
    fileprivate var url: URL
    fileprivate var readers = 0
    fileprivate var retired = false

    fileprivate init(identity: String, byteCount: Int64, contentType: String?, url: URL) {
      self.identity = identity
      self.byteCount = byteCount
      self.contentType = contentType
      self.url = url
    }
  }

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
  /// Guards client leases so policy checks never wait on the cache queue.
  private let stateLock = NSLock()
  private var clients: [UUID: Client] = [:]
  private var enabledClients = 0
  private var budgetState: Int64 = 0
  private var compatibilityClient: Client?

  // Cache-queue state.
  private var entries: [String: Entry] = [:]
  private var reservations: [UUID: Reservation] = [:]
  private var pins: [String: PinnedFile] = [:]
  private var retiredBytes: Int64 = 0
  private var evictionEpoch = 0
  private var identityEpochs: [String: Int] = [:]
  private var indexLoaded = false
  /// Pending LRU-stamp writes, coalesced onto one delayed barrier.
  private var indexWritePending = false
  private var indexWriteScheduled = false

  private let rootOverride: URL?

  init(rootURL: URL? = nil) {
    self.rootOverride = rootURL
  }

  private lazy var rootURL: URL = {
    if let rootOverride {
      return rootOverride
    }
    let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("native_feed_player", isDirectory: true)
  }()

  private var indexURL: URL {
    rootURL.appendingPathComponent("index.json")
  }

  private var stagingURL: URL {
    rootURL.appendingPathComponent("staging", isDirectory: true)
  }

  private var retiredURL: URL {
    rootURL.appendingPathComponent("retired", isDirectory: true)
  }

  // MARK: - Clients

  /// Leases the store with one engine's policy. The first enabled lease sets
  /// the shared budget; a conflicting budget waits until every enabled lease
  /// has been released.
  func register(enabled: Bool, maxBytes: Int64) -> Client {
    let client = Client(enabled: enabled, maxBytes: maxBytes)
    stateLock.withLock {
      clients[client.id] = client
      guard enabled else {
        return
      }
      if enabledClients == 0 {
        budgetState = maxBytes
      } else if budgetState != maxBytes {
        NSLog(
          "native_feed_player: cache budget %lld ignored while another engine holds the cache.",
          maxBytes
        )
      }
      enabledClients += 1
    }
    guard enabled else {
      return client
    }
    // Lookups made through this lease are submitted after this barrier, so
    // they always see a fully loaded index.
    queue.async(flags: .barrier) {
      try? self.fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
      if !self.indexLoaded {
        self.indexLoaded = true
        self.loadIndexLocked()
        self.removeOrphanedWorkLocked()
      }
      self.enforceBudgetLocked()
    }
    return client
  }

  /// Ends a lease and discards its unfinished staging work. Completed
  /// entries stay cached for other and future engines.
  func release(_ client: Client) {
    let wasLive: Bool = stateLock.withLock {
      guard !client.released else {
        return false
      }
      client.released = true
      clients.removeValue(forKey: client.id)
      if client.enabled {
        enabledClients -= 1
      }
      return true
    }
    guard wasLive else {
      return
    }
    queue.async(flags: .barrier) {
      for reservation in self.reservations.values where reservation.clientId == client.id {
        self.cancelReservationLocked(reservation)
      }
    }
  }

  /// Single-lease convenience kept for tests and tooling: replaces the
  /// store's own lease with one using this policy.
  func configure(enabled: Bool, maxBytes: Int64) {
    let previous = stateLock.withLock { compatibilityClient }
    if let previous {
      release(previous)
    }
    let client = register(enabled: enabled, maxBytes: maxBytes)
    stateLock.withLock { compatibilityClient = client }
  }

  /// Blocks until all queued cache work (including a pending configure) has
  /// finished. Testing hook only.
  func waitForPendingWorkForTesting() {
    queue.sync(flags: .barrier) {}
  }

  /// Whether any engine currently has caching enabled.
  var isEnabled: Bool {
    stateLock.withLock { enabledClients > 0 }
  }

  /// A nil client means "any enabled lease", the single-engine behaviour.
  private func isLive(_ client: Client?) -> Bool {
    stateLock.withLock {
      guard let client else {
        return enabledClients > 0
      }
      return client.enabled && !client.released
    }
  }

  private var budget: Int64 {
    stateLock.withLock { budgetState }
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
  func cachedFile(
    forIdentity identity: String,
    client: Client? = nil
  ) -> (url: URL, contentType: String?, byteCount: Int64)? {
    queue.sync(flags: .barrier) {
      guard isLive(client), var entry = validEntryLocked(identity: identity) else {
        return nil
      }
      entry.lastAccess = Date().timeIntervalSince1970
      entries[identity] = entry
      scheduleIndexWriteLocked()
      return (fileURL(forKey: identity), entry.contentType, entry.byteCount)
    }
  }

  /// Opens a complete entry and pins it until `unpin`. An evicted pinned
  /// file keeps counting against the budget until its last reader leaves.
  func pinnedFile(forIdentity identity: String, client: Client) -> (PinnedFile, FileHandle)? {
    queue.sync(flags: .barrier) {
      guard isLive(client), var entry = validEntryLocked(identity: identity),
        let handle = try? FileHandle(forReadingFrom: fileURL(forKey: identity))
      else {
        return nil
      }
      entry.lastAccess = Date().timeIntervalSince1970
      entries[identity] = entry
      scheduleIndexWriteLocked()
      let pin = pins[identity] ?? PinnedFile(
        identity: identity, byteCount: entry.byteCount,
        contentType: entry.contentType, url: fileURL(forKey: identity)
      )
      pin.readers += 1
      pins[identity] = pin
      return (pin, handle)
    }
  }

  func unpin(_ pin: PinnedFile) {
    queue.async(flags: .barrier) {
      pin.readers -= 1
      guard pin.readers <= 0 else {
        return
      }
      if pin.retired {
        try? self.fileManager.removeItem(at: pin.url)
        self.retiredBytes -= pin.byteCount
        pin.retired = false
      } else if self.pins[pin.identity] === pin {
        self.pins.removeValue(forKey: pin.identity)
      }
    }
  }

  func cachedBytes(forIdentity identity: String, completion: @escaping (Int64) -> Void) {
    queue.async(flags: .barrier) {
      completion(self.validEntryLocked(identity: identity)?.byteCount ?? 0)
    }
  }

  /// Bytes held by completed entries. Staging reservations and retired
  /// pinned files are budgeted internally but not reported here.
  func usageBytes(completion: @escaping (Int64) -> Void) {
    queue.async {
      completion(self.entries.values.reduce(0) { $0 + $1.byteCount })
    }
  }

  // MARK: - Reservations

  /// Reserves `bytes` for a download that will become `identity`, evicting
  /// unpinned entries to make room. Returns nil when the download cannot be
  /// cached; the caller then streams it from memory instead.
  func reserve(bytes: Int64, identity: String, client: Client) -> Reservation? {
    guard bytes > 0, bytes <= client.maxBytes else {
      return nil
    }
    return queue.sync(flags: .barrier) {
      guard isLive(client), bytes <= budget, makeRoomLocked(for: bytes) else {
        return nil
      }
      try? fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
      let url = stagingURL.appendingPathComponent(UUID().uuidString)
      guard fileManager.createFile(atPath: url.path, contents: nil) else {
        return nil
      }
      let reservation = Reservation(
        url: url, bytes: bytes, identity: identity, clientId: client.id,
        epoch: evictionEpoch, identityEpoch: identityEpochs[identity, default: 0]
      )
      reservations[reservation.id] = reservation
      return reservation
    }
  }

  func cancel(_ reservation: Reservation) {
    queue.async(flags: .barrier) {
      self.cancelReservationLocked(reservation)
    }
  }

  /// Moves a fully written staging file into the cache, transferring its
  /// reserved capacity. The adopted entry is returned pinned for the caller,
  /// whose open handle keeps reading it; nil means the adoption was refused
  /// (lease released, entry evicted meanwhile, or size mismatch).
  func adopt(
    _ reservation: Reservation,
    contentType: String?,
    completion: @escaping (PinnedFile?) -> Void
  ) {
    queue.async(flags: .barrier) {
      guard self.reservations.removeValue(forKey: reservation.id) != nil else {
        completion(nil)
        return
      }
      let identity = reservation.identity
      let client = self.stateLock.withLock { self.clients[reservation.clientId] }
      let size = (try? self.fileManager.attributesOfItem(atPath: reservation.url.path))?[.size] as? Int64
      guard let client, self.isLive(client),
        reservation.epoch == self.evictionEpoch,
        reservation.identityEpoch == self.identityEpochs[identity, default: 0],
        size == reservation.bytes
      else {
        try? self.fileManager.removeItem(at: reservation.url)
        completion(nil)
        return
      }
      if self.entries[identity] != nil {
        self.removeEntryLocked(key: identity)
      }
      let destination = self.fileURL(forKey: identity)
      try? self.fileManager.removeItem(at: destination)
      do {
        try self.fileManager.moveItem(at: reservation.url, to: destination)
      } catch {
        try? self.fileManager.removeItem(at: reservation.url)
        completion(nil)
        return
      }
      self.entries[identity] = Entry(
        key: identity, contentType: contentType, byteCount: reservation.bytes,
        lastAccess: Date().timeIntervalSince1970
      )
      let pin = PinnedFile(
        identity: identity, byteCount: reservation.bytes, contentType: contentType, url: destination
      )
      pin.readers = 1
      self.pins[identity] = pin
      self.saveIndexLocked()
      self.enforceBudgetLocked()
      completion(pin)
    }
  }

  // MARK: - Mutation

  /// Adopts a completed download into the cache. Ownership of the temporary
  /// file transfers to the cache queue immediately.
  func store(
    temporaryFile: URL,
    identity: String,
    contentType: String?,
    client: Client? = nil,
    completion: (() -> Void)? = nil
  ) {
    queue.async(flags: .barrier) {
      guard self.isLive(client) else {
        try? self.fileManager.removeItem(at: temporaryFile)
        completion?()
        return
      }
      let destination = self.fileURL(forKey: identity)
      if let existing = self.entries[identity],
        let size = try? self.fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64,
        size == existing.byteCount
      {
        if temporaryFile != destination {
          try? self.fileManager.removeItem(at: temporaryFile)
        }
        completion?()
        return
      }
      if self.entries[identity] != nil {
        self.removeEntryLocked(key: identity)
      }
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

  /// Removes entries and invalidates in-flight reservations for them, so a
  /// download that finishes afterwards cannot repopulate an evicted entry.
  func evict(identities: Set<String>, completion: @escaping () -> Void) {
    queue.async(flags: .barrier) {
      for identity in identities {
        self.identityEpochs[identity, default: 0] += 1
        if self.entries[identity] != nil {
          self.removeEntryLocked(key: identity)
        }
      }
      self.saveIndexLocked()
      completion()
    }
  }

  func evictAll(completion: @escaping () -> Void) {
    queue.async(flags: .barrier) {
      self.evictionEpoch += 1
      for key in Array(self.entries.keys) {
        self.removeEntryLocked(key: key)
      }
      self.saveIndexLocked()
      completion()
    }
  }

  // MARK: - Testing

  func storageForTesting(completion: @escaping (_ entries: Int64, _ reserved: Int64, _ retired: Int64) -> Void) {
    queue.async(flags: .barrier) {
      completion(self.entryBytesLocked, self.reservedBytesLocked, self.retiredBytes)
    }
  }

  // MARK: - Locked helpers

  private var entryBytesLocked: Int64 {
    entries.values.reduce(Int64(0)) { $0 + $1.byteCount }
  }

  private var reservedBytesLocked: Int64 {
    reservations.values.reduce(Int64(0)) { $0 + $1.bytes }
  }

  private func cancelReservationLocked(_ reservation: Reservation) {
    guard reservations.removeValue(forKey: reservation.id) != nil else {
      return
    }
    try? fileManager.removeItem(at: reservation.url)
  }

  /// Verify the on-disk size still matches the index: a truncated file
  /// (crash mid-move, external eviction) must not be served with the
  /// recorded content length.
  private func validEntryLocked(identity: String) -> Entry? {
    guard let entry = entries[identity] else {
      return nil
    }
    let sizeOnDisk = (try? fileManager.attributesOfItem(atPath: fileURL(forKey: identity).path))?[
      .size
    ] as? Int64
    guard sizeOnDisk == entry.byteCount else {
      removeEntryLocked(key: identity)
      saveIndexLocked()
      return nil
    }
    return entry
  }

  /// Pinned files move aside instead of disappearing, and keep counting
  /// against the budget until their readers finish.
  private func removeEntryLocked(key: String) {
    let url = fileURL(forKey: key)
    if let pin = pins.removeValue(forKey: key) {
      try? fileManager.createDirectory(at: retiredURL, withIntermediateDirectories: true)
      let retired = retiredURL.appendingPathComponent(UUID().uuidString)
      if (try? fileManager.moveItem(at: url, to: retired)) != nil {
        pin.url = retired
        pin.retired = true
        retiredBytes += pin.byteCount
      } else {
        try? fileManager.removeItem(at: url)
      }
    } else {
      try? fileManager.removeItem(at: url)
    }
    entries.removeValue(forKey: key)
  }

  /// Evicts least recently used unpinned entries until `bytes` more fit.
  private func makeRoomLocked(for bytes: Int64) -> Bool {
    let limit = budget
    guard limit > 0 else {
      return false
    }
    var total = entryBytesLocked + reservedBytesLocked + retiredBytes
    if total + bytes > limit {
      let ordered = entries.values
        .filter { pins[$0.key] == nil }
        .sorted { $0.lastAccess < $1.lastAccess }
      for entry in ordered where total + bytes > limit {
        total -= entry.byteCount
        removeEntryLocked(key: entry.key)
      }
      saveIndexLocked()
    }
    return total + bytes <= limit
  }

  /// Drops least recently used entries until the store fits the budget.
  private func enforceBudgetLocked() {
    guard budget > 0 else {
      return
    }
    _ = makeRoomLocked(for: 0)
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

  /// Staging and retired files from a previous process have no owner left.
  /// Runs once, before any lease can reserve new staging work.
  private func removeOrphanedWorkLocked() {
    for directory in [stagingURL, retiredURL] {
      try? fileManager.removeItem(at: directory)
    }
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
