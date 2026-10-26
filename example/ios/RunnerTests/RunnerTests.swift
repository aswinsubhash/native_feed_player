import AVFoundation
import XCTest
import UIKit

@testable import native_feed_player

final class FeedSourceRegistryTests: XCTestCase {
  private func source(
    _ id: String,
    rank: Int,
    uri: String? = nil,
    headers: [String: String] = [:]
  ) -> RegisteredSource {
    RegisteredSource(
      id: id,
      uri: uri ?? "https://example.test/\(id).mp4",
      rank: rank,
      kind: .auto,
      headers: headers
    )
  }

  private func registry(count: Int, visible: String? = nil) -> FeedSourceRegistry {
    let registry = FeedSourceRegistry()
    registry.replaceAll((0..<count).map { source("s\($0)", rank: $0) })
    if let visible {
      registry.setVisible(visible)
    }
    return registry
  }

  func testReplaceAllDefaultsVisibleToLowestRank() {
    XCTAssertEqual(registry(count: 3).visibleSourceId, "s0")
  }

  func testAppendPreservesExistingRanks() {
    let registry = self.registry(count: 2, visible: "s1")
    registry.append([source("page2", rank: 2), source("page3", rank: 3)])

    XCTAssertEqual(registry.visibleSourceId, "s1")
    XCTAssertEqual(registry.visibleRank(), 1)
    XCTAssertEqual(registry.count, 4)
    XCTAssertEqual(registry.source(id: "page2")?.rank, 2)
  }

  func testWindowIsBiasedForward() {
    let registry = self.registry(count: 10, visible: "s5")

    let ids = registry.preloadWindow(ahead: 2, behind: 1).map(\.id)

    XCTAssertEqual(ids, ["s5", "s4", "s6", "s7"])
  }

  func testWindowClampsAtFeedBounds() {
    let registry = self.registry(count: 3, visible: "s0")

    let ids = registry.preloadWindow(ahead: 5, behind: 5).map(\.id)

    XCTAssertEqual(ids, ["s0", "s1", "s2"])
  }

  func testWindowIsEmptyWithoutSources() {
    let registry = FeedSourceRegistry()

    XCTAssertTrue(registry.preloadWindow(ahead: 2, behind: 1).isEmpty)
    XCTAssertNil(registry.visibleRank())
  }

  func testDirectionIsInferredFromSuccessiveViewportUpdates() {
    let registry = self.registry(count: 5)
    XCTAssertEqual(registry.direction, .unknown)

    registry.setVisible("s1")
    XCTAssertEqual(registry.direction, .forward)

    registry.setVisible("s0")
    XCTAssertEqual(registry.direction, .backward)
  }

  func testWindowFollowsTravelWhenScrollingBackwards() {
    let registry = self.registry(count: 10)
    registry.setVisible("s5")
    registry.setVisible("s4")

    let ids = registry.preloadWindow(ahead: 2, behind: 1).map(\.id)

    XCTAssertEqual(ids, ["s4", "s3", "s5", "s2"])
  }

  func testWindowCollapsesDuplicateUris() {
    let registry = FeedSourceRegistry()
    let repeated = "https://example.test/repeat.mp4"
    registry.replaceAll([
      source("a", rank: 0),
      source("b", rank: 1, uri: repeated),
      source("c", rank: 2, uri: repeated),
    ])
    registry.setVisible("a")

    let ids = registry.preloadWindow(ahead: 3, behind: 0).map(\.id)

    XCTAssertEqual(ids, ["a", "b"])
  }

  func testWindowShrinksWithScale() {
    let registry = self.registry(count: 10, visible: "s5")

    let full = registry.preloadWindow(ahead: 4, behind: 2, scale: 1.0)
    let halved = registry.preloadWindow(ahead: 4, behind: 2, scale: 0.5)

    XCTAssertLessThan(halved.count, full.count)
    XCTAssertEqual(halved.first?.id, "s5")
  }

  func testDistanceFromVisibleUsesRankNotInsertionOrder() {
    let registry = FeedSourceRegistry()
    registry.replaceAll([
      source("c", rank: 2),
      source("a", rank: 0),
      source("b", rank: 1),
    ])
    registry.setVisible("a")

    XCTAssertEqual(registry.distanceFromVisible(id: "a"), 0)
    XCTAssertEqual(registry.distanceFromVisible(id: "b"), 1)
    XCTAssertEqual(registry.distanceFromVisible(id: "c"), 2)
    XCTAssertNil(registry.distanceFromVisible(id: "missing"))
  }

  func testRemoveMovesVisibleToLowestRemainingRank() {
    let registry = self.registry(count: 3, visible: "s1")
    registry.remove(ids: ["s1"])

    XCTAssertEqual(registry.visibleSourceId, "s0")
    XCTAssertEqual(registry.count, 2)
  }

  func testSetVisibleIgnoresUnknownSource() {
    let registry = self.registry(count: 2, visible: "s1")
    registry.setVisible("does-not-exist")

    XCTAssertEqual(registry.visibleSourceId, "s1")
  }

  func testBlankUriSourcesAreSkipped() {
    let registry = FeedSourceRegistry()
    registry.replaceAll([
      source("ok", rank: 0),
      RegisteredSource(id: "blank", uri: "", rank: 1, kind: .auto, headers: [:]),
    ])

    XCTAssertEqual(registry.count, 1)
    XCTAssertNil(registry.source(id: "blank"))
  }

  func testUnknownVisibleSourceDoesNotChangeVisibility() {
    let registry = self.registry(count: 2, visible: "s1")

    XCTAssertFalse(registry.setVisible("missing"))
    XCTAssertEqual(registry.visibleSourceId, "s1")
  }

  func testSparseRanksAreNotCompactedByWindowLookup() {
    let registry = FeedSourceRegistry()
    registry.replaceAll([
      source("near", rank: 101), source("far", rank: 1_000_000),
      source("visible", rank: 100), source("behind", rank: 98),
    ])
    registry.setVisible("visible")
    XCTAssertEqual(registry.preloadWindow(ahead: 2, behind: 1).map(\.id), ["visible", "near"])
    registry.setVisible("near")
    registry.setVisible("visible")
    XCTAssertEqual(
      registry.preloadWindow(ahead: 2, behind: 1).map(\.id), ["visible", "near", "behind"]
    )
  }

  func testRankIndexTracksReplacementRemovalAndClear() {
    let registry = self.registry(count: 3)
    registry.append([source("s1", rank: 100)])
    XCTAssertEqual(registry.preloadWindow(ahead: 2, behind: 0).map(\.id), ["s0", "s2"])
    registry.remove(ids: ["s0"])
    XCTAssertEqual(registry.visibleSourceId, "s2")
    registry.replaceAll([source("new", rank: 50)])
    XCTAssertEqual(registry.preloadWindow(ahead: 2, behind: 2).map(\.id), ["new"])
    registry.clear()
    XCTAssertTrue(registry.preloadWindow(ahead: 2, behind: 2).isEmpty)
  }

  func testEqualRanksAndDuplicateIdentitiesHaveDeterministicOrdering() {
    let registry = FeedSourceRegistry()
    registry.replaceAll([
      source("z", rank: 0), source("b", rank: 1, uri: "file:///duplicate"),
      source("a", rank: 1, uri: "file:///duplicate"),
    ])
    XCTAssertEqual(registry.preloadWindow(ahead: 1, behind: 0).map(\.id), ["z", "a"])
    registry.setVisible("b")
    XCTAssertEqual(registry.preloadWindow(ahead: 0, behind: 0).map(\.id), ["b"])
  }

  func testPlaybackIdentityIncludesFreshURLKindCredentialsAndCacheKey() {
    let old = RegisteredSource(
      id: "clip", uri: "https://cdn.test/clip.mp4?token=old", rank: 0,
      kind: .progressive, headers: ["Authorization": "one"], cacheKey: "stable"
    )
    let refreshed = RegisteredSource(
      id: "clip", uri: "https://cdn.test/clip.mp4?token=new", rank: 0,
      kind: .progressive, headers: ["authorization": "one"], cacheKey: "stable"
    )
    XCTAssertEqual(old.cacheIdentity, refreshed.cacheIdentity)
    XCTAssertNotEqual(old.playbackIdentity, refreshed.playbackIdentity)
    for replacement in [
      RegisteredSource(id: old.id, uri: old.uri, rank: 0, kind: .auto, headers: old.headers, cacheKey: old.cacheKey),
      RegisteredSource(id: old.id, uri: old.uri, rank: 0, kind: old.kind, headers: ["Authorization": "two"], cacheKey: old.cacheKey),
      RegisteredSource(id: old.id, uri: old.uri, rank: 0, kind: old.kind, headers: old.headers, cacheKey: "different"),
      RegisteredSource(id: old.id, uri: old.uri, rank: 0, kind: old.kind, headers: old.headers, cacheKey: " stable "),
      RegisteredSource(id: old.id, uri: old.uri, rank: 0, kind: old.kind, headers: ["authorization": "one"], cacheKey: old.cacheKey),
    ] {
      XCTAssertNotEqual(old.playbackIdentity, replacement.playbackIdentity)
    }
    let reordered = RegisteredSource(
      id: "another-id", uri: old.uri, rank: 10, kind: old.kind,
      headers: old.headers, cacheKey: old.cacheKey
    )
    XCTAssertEqual(old.playbackIdentity, reordered.playbackIdentity)
  }

  func testWindowKeepsSameUriWithDifferentCredentials() {
    let registry = FeedSourceRegistry()
    let uri = "https://example.test/private.mp4"
    registry.replaceAll([
      source("a", rank: 0, uri: uri, headers: ["Authorization": "Bearer a"]),
      source("b", rank: 1, uri: uri, headers: ["authorization": "Bearer b"]),
    ])

    XCTAssertEqual(registry.preloadWindow(ahead: 1, behind: 0).map(\.id), ["a", "b"])
  }
}

final class CachingResourceLoaderTests: XCTestCase {
  func testInterceptedUrlRoundTrips() {
    let original = "https://example.test/clip.mp4?token=abc"

    guard let intercepted = CachingResourceLoader.interceptURL(for: original) else {
      return XCTFail("expected an intercepted URL")
    }

    XCTAssertTrue(intercepted.scheme?.hasPrefix("nfpcache-https-") == true)
    XCTAssertEqual(
      CachingResourceLoader.originalURL(from: intercepted)?.absoluteString,
      original
    )
  }

  func testNonInterceptedUrlIsRejected() {
    let plain = URL(string: "https://example.test/clip.mp4")!

    XCTAssertNil(CachingResourceLoader.originalURL(from: plain))
  }

  func testCacheKeysAreStableAndDistinct() {
    let a = MediaDiskCache.key(for: "https://example.test/a.mp4")
    let b = MediaDiskCache.key(for: "https://example.test/b.mp4")

    XCTAssertEqual(a, MediaDiskCache.key(for: "https://example.test/a.mp4"))
    XCTAssertNotEqual(a, b)
    XCTAssertEqual(a.count, 64, "SHA-256 hex digest")
  }

  func testCacheIdentityCanonicalizesHeaderOrderAndCase() {
    let uri = "https://example.test/private.mp4?token=uri-secret"
    let first = MediaCacheIdentity.make(
      uri: uri,
      headers: ["Authorization": "Bearer secret", "X-Tenant": "abc"]
    )
    let reordered = MediaCacheIdentity.make(
      uri: uri,
      headers: ["x-tenant": "abc", "authorization": "Bearer secret"]
    )

    XCTAssertEqual(first, reordered)
    XCTAssertEqual(first.count, 64)
    XCTAssertFalse(first.contains("secret"))
    XCTAssertFalse(first.contains("token"))
  }

  func testCacheIdentityChangesWithCredentials() {
    let uri = "https://example.test/private.mp4"
    let first = MediaCacheIdentity.make(uri: uri, headers: ["Authorization": "Bearer a"])
    let second = MediaCacheIdentity.make(uri: uri, headers: ["Authorization": "Bearer b"])

    XCTAssertNotEqual(first, second)
    XCTAssertNotEqual(
      CachingResourceLoader.interceptURL(for: uri, headers: ["Authorization": "Bearer a"]),
      CachingResourceLoader.interceptURL(for: uri, headers: ["Authorization": "Bearer b"])
    )
  }

  func testInterceptedUrlIdentityHonoursCacheKey() {
    let a = CachingResourceLoader.interceptURL(
      for: "https://cdn.test/v.mp4?sig=one", headers: [:], cacheKey: "episode-42")
    let b = CachingResourceLoader.interceptURL(
      for: "https://cdn.test/v.mp4?sig=two", headers: [:], cacheKey: "episode-42")
    let c = CachingResourceLoader.interceptURL(
      for: "https://cdn.test/v.mp4?sig=one", headers: [:], cacheKey: "episode-43")

    // The loader's identity must match RegisteredSource.cacheIdentity, which
    // already honours cacheKey; same cacheKey shares one entry.
    XCTAssertEqual(a?.scheme, b?.scheme)
    XCTAssertNotEqual(a?.scheme, c?.scheme)
    XCTAssertEqual(
      CachingResourceLoader.identity(from: a!),
      MediaCacheIdentity.make(uri: "https://cdn.test/v.mp4?sig=one", headers: [:], cacheKey: "episode-42")
    )
  }

  func testOnlySuccessfulHttpResponsesAreCacheable() {
    XCTAssertTrue(CachingResourceLoader.isSuccessfulHTTPStatus(200))
    XCTAssertTrue(CachingResourceLoader.isSuccessfulHTTPStatus(206))
    XCTAssertFalse(CachingResourceLoader.isSuccessfulHTTPStatus(302))
    XCTAssertFalse(CachingResourceLoader.isSuccessfulHTTPStatus(401))
    XCTAssertFalse(CachingResourceLoader.isSuccessfulHTTPStatus(500))
  }

  func testContentRangeParsingIsStrict() {
    typealias R = CachingResourceLoader.ContentRange
    XCTAssertEqual(CachingResourceLoader.parseContentRange("bytes 0-99/1000"), R(start: 0, end: 99, total: 1000))
    XCTAssertEqual(CachingResourceLoader.parseContentRange("bytes 900-999/1000"), R(start: 900, end: 999, total: 1000))
    XCTAssertEqual(CachingResourceLoader.parseContentRange("bytes 5-9/*"), R(start: 5, end: 9, total: nil))
    XCTAssertEqual(CachingResourceLoader.parseContentRange("bytes */1000"), R(start: nil, end: nil, total: 1000))
    for invalid in [
      nil, "", "bytes 10-5/100", "bytes 0-100/100", "bytes -1-5/100", "items 0-1/2",
      "bytes 0-1", "bytes */*", "bytes 0-1/abc", "bytes 0-99999999999999999999/1",
    ] {
      XCTAssertNil(CachingResourceLoader.parseContentRange(invalid), invalid ?? "nil")
    }
  }

  func testMimeTypesAreConvertedToUniformTypeIdentifiers() {
    XCTAssertEqual(CachingResourceLoader.contentType(forMimeType: "video/mp4"), "public.mpeg-4")
    XCTAssertEqual(CachingResourceLoader.normalizedContentType("video/mp4"), "public.mpeg-4")
    XCTAssertEqual(CachingResourceLoader.normalizedContentType("public.mpeg-4"), "public.mpeg-4")
    XCTAssertNil(CachingResourceLoader.contentType(forMimeType: nil))
  }

  func testCacheKeyReplacesUriInIdentityButHeadersStillMatter() {
    let base = MediaCacheIdentity.make(
      uri: "https://cdn.test/video.mp4?sig=one",
      headers: [:],
      cacheKey: "episode-42"
    )
    let rotatedSignature = MediaCacheIdentity.make(
      uri: "https://cdn.test/video.mp4?sig=two",
      headers: [:],
      cacheKey: "episode-42"
    )
    let differentKey = MediaCacheIdentity.make(
      uri: "https://cdn.test/video.mp4?sig=one",
      headers: [:],
      cacheKey: "episode-43"
    )
    let differentHeaders = MediaCacheIdentity.make(
      uri: "https://cdn.test/video.mp4?sig=one",
      headers: ["Authorization": "Bearer t"],
      cacheKey: "episode-42"
    )

    XCTAssertEqual(base, rotatedSignature)
    XCTAssertNotEqual(base, differentKey)
    XCTAssertNotEqual(base, differentHeaders)
  }

  func testChunkedServingBoundsSingleResponses() {
    // The serving contract: one respond() call never exceeds the chunk size,
    // so an open-ended request cannot materialise a whole cached file.
    XCTAssertGreaterThan(CachingResourceLoader.chunkSize, 0)
    XCTAssertLessThanOrEqual(CachingResourceLoader.chunkSize, 1024 * 1024)
  }

  func testChunkPlanBoundedRequests() {
    let chunk = Int64(CachingResourceLoader.chunkSize)
    // A 3 MB file, request for bytes 0..<2 MB: first chunk, then remainder.
    XCTAssertEqual(
      CachingResourceLoader.chunkPlan(
        requestedLength: 2_000_000, alreadyServed: 0, currentOffset: 0, byteCount: 3_000_000
      ),
      chunk
    )
    XCTAssertEqual(
      CachingResourceLoader.chunkPlan(
        requestedLength: 2_000_000,
        alreadyServed: chunk,
        currentOffset: chunk,
        byteCount: 3_000_000
      ),
      min(2_000_000 - chunk, chunk)
    )
    // Fully served.
    XCTAssertEqual(
      CachingResourceLoader.chunkPlan(
        requestedLength: 2_000_000,
        alreadyServed: 2_000_000,
        currentOffset: 2_000_000,
        byteCount: 3_000_000
      ),
      0
    )
  }

  func testChunkPlanOpenEndedAndEdgeCases() {
    let chunk = Int64(CachingResourceLoader.chunkSize)
    // Open-ended request against a 3 MB file: requestedLength must be ignored.
    XCTAssertEqual(
      CachingResourceLoader.chunkPlan(
        requestedLength: 1,
        alreadyServed: 0,
        currentOffset: 0,
        byteCount: 3_000_000,
        requestsAllDataToEndOfResource: true
      ),
      chunk
    )
    // Near the end of the file: clamp to what remains.
    XCTAssertEqual(
      CachingResourceLoader.chunkPlan(
        requestedLength: 1,
        alreadyServed: 2_999_000,
        currentOffset: 2_999_000,
        byteCount: 3_000_000,
        requestsAllDataToEndOfResource: true
      ),
      1_000
    )
    // Past EOF or fully consumed: nothing to serve.
    XCTAssertEqual(
      CachingResourceLoader.chunkPlan(
        requestedLength: 1,
        alreadyServed: 3_000_000,
        currentOffset: 3_000_000,
        byteCount: 3_000_000,
        requestsAllDataToEndOfResource: true
      ),
      0
    )
    // Tiny file smaller than one chunk.
    XCTAssertEqual(
      CachingResourceLoader.chunkPlan(
        requestedLength: 500, alreadyServed: 0, currentOffset: 0, byteCount: 100
      ),
      100
    )
  }
}

final class MediaDiskCacheTests: XCTestCase {
  private let cacheRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("nfp-cache-tests-\(UUID().uuidString)", isDirectory: true)
  private lazy var cache = MediaDiskCache(rootURL: cacheRoot)

  override func tearDown() {
    cache.evictAll { [cache] in
      cache.configure(enabled: false, maxBytes: 0)
    }
    // The next test's configure must not race this teardown on the cache queue.
    cache.waitForPendingWorkForTesting()
    try? FileManager.default.removeItem(at: cacheRoot)
    super.tearDown()
  }

  func testConfigureAppliesTheNewBudgetToTheLoadBarrier() throws {
    // Seed a 4 KB entry under a generous budget.
    cache.configure(enabled: true, maxBytes: 64 * 1024 * 1024)
    cache.waitForPendingWorkForTesting()
    let identity = MediaCacheIdentity.make(
      uri: "https://example.test/budget-\(UUID().uuidString).mp4",
      headers: [:]
    )
    let temporary = cacheRoot
      .appendingPathComponent("nfp-test-\(UUID().uuidString)")
    try Data(repeating: 0xAB, count: 4096).write(to: temporary)
    cache.store(temporaryFile: temporary, identity: identity, contentType: "video/mp4")
    cache.waitForPendingWorkForTesting()
    XCTAssertNotNil(cache.cachedFile(forIdentity: identity))

    // Reconfigure with a 1 KB budget: the load barrier must enforce the NEW
    // budget, not the previous one, and evict the 4 KB entry.
    cache.configure(enabled: true, maxBytes: 1024)
    XCTAssertTrue(cache.isEnabled)
    cache.waitForPendingWorkForTesting()
    XCTAssertNil(cache.cachedFile(forIdentity: identity))
  }

  func testTruncatedCacheFileIsEvictedInsteadOfServed() throws {
    cache.configure(enabled: true, maxBytes: 64 * 1024 * 1024)
    cache.waitForPendingWorkForTesting()

    let identity = MediaCacheIdentity.make(
      uri: "https://example.test/truncated-\(UUID().uuidString).mp4",
      headers: [:]
    )
    let payload = Data(repeating: 0xAB, count: 4096)
    let temporary = cacheRoot
      .appendingPathComponent("nfp-test-\(UUID().uuidString)")
    try payload.write(to: temporary)
    cache.store(temporaryFile: temporary, identity: identity, contentType: "video/mp4")
    cache.waitForPendingWorkForTesting()

    XCTAssertNotNil(cache.cachedFile(forIdentity: identity))

    // Simulate external truncation (crash mid-move, OS eviction).
    let url = cache.fileURL(forKey: identity)
    try Data(repeating: 0xCD, count: 1024).write(to: url)

    XCTAssertNil(cache.cachedFile(forIdentity: identity))
    cache.waitForPendingWorkForTesting()
    XCTAssertNil(cache.cachedFile(forIdentity: identity))
  }

  func testCachedBytesRejectsMissingAndTruncatedFilesBeforePlaybackLookup() throws {
    cache.configure(enabled: true, maxBytes: 64 * 1024 * 1024)
    cache.waitForPendingWorkForTesting()
    let valid = try storeEntry(named: "valid", bytes: 4096)
    let missing = try storeEntry(named: "missing", bytes: 4096)
    let truncated = try storeEntry(named: "truncated", bytes: 4096)
    try FileManager.default.removeItem(at: cache.fileURL(forKey: missing))
    try Data(repeating: 0xCD, count: 1024).write(to: cache.fileURL(forKey: truncated))

    XCTAssertEqual(cachedBytes(valid), 4096)
    XCTAssertEqual(cachedBytes(missing), 0)
    XCTAssertEqual(cachedBytes(truncated), 0)
    XCTAssertEqual(cachedBytes(missing), 0)
    XCTAssertEqual(cachedBytes(truncated), 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL(forKey: truncated).path))
    XCTAssertNil(cache.cachedFile(forIdentity: missing))
    XCTAssertNil(cache.cachedFile(forIdentity: truncated))
    XCTAssertNotNil(cache.cachedFile(forIdentity: valid))
    let usage = expectation(description: "usage")
    cache.usageBytes { bytes in
      XCTAssertEqual(bytes, 4096)
      usage.fulfill()
    }
    wait(for: [usage], timeout: 2)
  }

  private func storeEntry(named name: String, bytes: Int) throws -> String {
    let identity = MediaCacheIdentity.make(
      uri: "https://example.test/\(name)-\(UUID().uuidString).mp4",
      headers: [:]
    )
    let temporary = cacheRoot.appendingPathComponent("nfp-test-\(UUID().uuidString)")
    try Data(repeating: 0xAB, count: bytes).write(to: temporary)
    cache.store(temporaryFile: temporary, identity: identity, contentType: "video/mp4")
    cache.waitForPendingWorkForTesting()
    return identity
  }

  private func cachedBytes(_ identity: String) -> Int64 {
    let done = expectation(description: "cached bytes")
    var result: Int64 = -1
    cache.cachedBytes(forIdentity: identity) { bytes in
      result = bytes
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
    return result
  }
}

final class AdaptivePreloadPolicyTests: XCTestCase {
  func testRepeatedRebuffersDegradeWindow() {
    var policy = AdaptivePreloadPolicy()

    XCTAssertFalse(policy.noteRebuffer(at: 1_000))
    XCTAssertFalse(policy.noteRebuffer(at: 2_000))
    XCTAssertTrue(policy.noteRebuffer(at: 3_000))
    XCTAssertEqual(policy.scale, 0.5)
  }

  func testPlayingEventDoesNotImmediatelyRecoverWindow() {
    var policy = AdaptivePreloadPolicy()
    _ = policy.noteMemoryPressure(at: 1_000)

    XCTAssertFalse(policy.notePlaybackProgress(at: 1_001))
    XCTAssertFalse(
      policy.notePlaybackProgress(
        at: 1_000 + AdaptivePreloadPolicy.stableRecoveryIntervalMs - 1
      )
    )
    XCTAssertEqual(policy.scale, AdaptivePreloadPolicy.minimumScale)

    XCTAssertTrue(
      policy.notePlaybackProgress(
        at: 1_001 + AdaptivePreloadPolicy.stableRecoveryIntervalMs
      )
    )
    XCTAssertEqual(policy.scale, 0.5)
  }

  func testRebufferRestartsStableRecoveryClock() {
    var policy = AdaptivePreloadPolicy()
    _ = policy.noteMemoryPressure(at: 0)
    _ = policy.notePlaybackProgress(at: 1_000)
    _ = policy.noteRebuffer(at: 10_000)

    XCTAssertFalse(policy.notePlaybackProgress(at: 20_000))
    XCTAssertEqual(policy.scale, AdaptivePreloadPolicy.minimumScale)
  }
}

final class PlatformViewRegistryTests: XCTestCase {
  func testStaleDisposalDoesNotRemoveReplacementView() {
    let registry = PlatformViewRegistry<Int64, NSObject>()
    let oldView = NSObject()
    let newView = NSObject()

    registry.register(oldView, for: 7)
    registry.register(newView, for: 7)

    XCTAssertFalse(registry.removeIfCurrent(oldView, for: 7))
    XCTAssertTrue(registry[7] === newView)
  }

  func testCurrentViewIsRemovedExactlyOnce() {
    let registry = PlatformViewRegistry<Int64, NSObject>()
    let view = NSObject()

    registry.register(view, for: 7)

    XCTAssertTrue(registry.removeIfCurrent(view, for: 7))
    XCTAssertNil(registry[7])
    XCTAssertFalse(registry.removeIfCurrent(view, for: 7))
  }
}

final class BufferedEventSinkTests: XCTestCase {
  func testReplacementSessionDropsBufferedEvents() {
    let holder = BufferedEventSink<String>()
    var events: [String] = []

    holder.emit("old")
    holder.clearPending()
    holder.attach(PigeonEventSink<String> { event in
      if let event = event as? String {
        events.append(event)
      }
    })
    holder.emit("new")

    XCTAssertEqual(events, ["new"])
  }

  func testReplacementListenerReceivesNewEvents() {
    let holder = BufferedEventSink<String>()
    var oldEvents: [String] = []
    var newEvents: [String] = []

    holder.attach(PigeonEventSink<String> { event in
      if let event = event as? String {
        oldEvents.append(event)
      }
    })
    holder.detach()
    holder.attach(PigeonEventSink<String> { event in
      if let event = event as? String {
        newEvents.append(event)
      }
    })
    holder.emit("new")

    XCTAssertTrue(oldEvents.isEmpty)
    XCTAssertEqual(newEvents, ["new"])
  }
}

final class AVPlayerManagerSessionTests: XCTestCase {
  private func config(
    manageAudioSession: Bool = true,
    muted: Bool = true,
    handleAudioFocus: Bool = false
  ) -> FeedPlayerConfigMessage {
    FeedPlayerConfigMessage(
      maxActivePlayers: 3,
      preloadAhead: 2,
      preloadBehind: 1,
      maxConcurrentPreloads: 2,
      positionUpdateIntervalMs: 200,
      renderMode: .platformView,
      cache: CachePolicyMessage(enabled: false, maxBytes: 0),
      audio: AudioPolicyMessage(
        muted: muted,
        volume: 1,
        handleAudioFocus: handleAudioFocus,
        manageAudioSession: manageAudioSession
      )
    )
  }

  func testInitializeReplacesPreviousSession() throws {
    var released: [(Int, ReleaseReasonMessage)] = []
    let manager = AVPlayerManager(
      onState: { _, _, _ in },
      onReleased: { released.append(($0, $1)) },
      onPosition: { _ in },
      onMetrics: { _ in },
      onVideoSize: { _ in }
    )
    let config = config()

    manager.initialize(config: config)
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 1, sourceId: "clip", autoPlay: false, looping: false)
    XCTAssertNotNil(manager.player(for: 1))

    manager.initialize(config: config)

    XCTAssertNil(manager.player(for: 1))
    XCTAssertEqual(released.count, 1)
    XCTAssertEqual(released.first?.0, 1)
    XCTAssertEqual(released.first?.1, .disposed)
  }

  func testManageAudioSessionFalseLeavesTheHostSessionUntouched() throws {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: [.duckOthers])
    defer {
      try? session.setCategory(.playback, mode: .moviePlayback, options: [])
    }

    let manager = AVPlayerManager(
      onState: { _, _, _ in },
      onReleased: { _, _ in },
      onPosition: { _ in },
      onMetrics: { _ in },
      onVideoSize: { _ in }
    )

    manager.initialize(config: config(manageAudioSession: false, muted: false))

    // The plugin must not have rewritten the category or dropped the
    // host app's options.
    XCTAssertEqual(session.category, .playback)
    XCTAssertTrue(session.categoryOptions.contains(.duckOthers))
  }

  func testManageAudioSessionTrueReconfiguresTheHostSession() throws {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: [.duckOthers])
    defer {
      try? session.setCategory(.playback, mode: .moviePlayback, options: [])
    }

    let manager = AVPlayerManager(
      onState: { _, _, _ in },
      onReleased: { _, _ in },
      onPosition: { _ in },
      onMetrics: { _ in },
      onVideoSize: { _ in }
    )

    manager.initialize(config: config(manageAudioSession: true, muted: false))

    XCTAssertEqual(session.category, .playback)
    XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
  }

  func testMutedPolicyConfiguresAnAmbientSessionInsteadOfThrowing() throws {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: [])
    defer {
      try? session.setCategory(.playback, mode: .moviePlayback, options: [])
    }

    let manager = AVPlayerManager(
      onState: { _, _, _ in },
      onReleased: { _, _ in },
      onPosition: { _ in },
      onMetrics: { _ in },
      onVideoSize: { _ in }
    )

    manager.initialize(config: config(manageAudioSession: true, muted: true))

    // .moviePlayback + .ambient made setCategory throw, so a muted feed never
    // actually reconfigured the session. The ambient path now succeeds.
    XCTAssertEqual(session.category, .ambient)
    XCTAssertEqual(session.mode, .default)
    XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
  }

  func testStaleRenderViewDetachKeepsReplacementAttached() throws {
    let manager = AVPlayerManager(
      onState: { _, _, _ in },
      onReleased: { _, _ in },
      onPosition: { _ in },
      onMetrics: { _ in },
      onVideoSize: { _ in }
    )
    manager.initialize(
      config: FeedPlayerConfigMessage(
        maxActivePlayers: 3,
        preloadAhead: 2,
        preloadBehind: 1,
        maxConcurrentPreloads: 2,
        positionUpdateIntervalMs: 200,
        renderMode: .platformView,
        cache: CachePolicyMessage(enabled: false, maxBytes: 0),
        audio: AudioPolicyMessage(muted: true, volume: 1, handleAudioFocus: false, manageAudioSession: true)
      )
    )
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 1, sourceId: "clip", autoPlay: false, looping: false)
    let oldView = NativeVideoRenderView()
    let newView = NativeVideoRenderView()

    manager.attach(controllerId: 1, renderView: oldView)
    manager.attach(controllerId: 1, renderView: newView)
    manager.detach(controllerId: 1, renderView: oldView)

    XCTAssertNil(oldView.playerLayer.player)
    XCTAssertTrue(newView.playerLayer.player === manager.player(for: 1))
  }

  func testReleaseDetachesRenderViewBeforeLifecycleCallback() throws {
    var renderView: NativeVideoRenderView?
    var wasDetachedAtRelease = false
    let manager = AVPlayerManager(
      onState: { _, _, _ in },
      onReleased: { _, _ in
        wasDetachedAtRelease = renderView?.playerLayer.player == nil
      },
      onPosition: { _ in },
      onMetrics: { _ in },
      onVideoSize: { _ in }
    )
    manager.initialize(config: testConfig())
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 5, sourceId: "clip", autoPlay: false, looping: false)
    renderView = NativeVideoRenderView()
    manager.attach(controllerId: 5, renderView: renderView!)

    manager.disposeController(controllerId: 5)

    XCTAssertTrue(wasDetachedAtRelease)
    XCTAssertNil(renderView?.playerLayer.player)
  }

  func testSetSourcesReleasesOrphanedController() throws {
    var released: [Int] = []
    let manager = makeManager(onReleased: { released.append($0) })
    manager.initialize(config: testConfig(preloadAhead: 0, preloadBehind: 0))
    try manager.setSources([
      RegisteredSource(id: "old", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 7, sourceId: "old", autoPlay: false, looping: false)

    try manager.setSources([
      RegisteredSource(id: "new", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])

    XCTAssertNil(manager.player(for: 7))
    XCTAssertEqual(released, [7])
  }

  func testUnknownVisibilityDoesNotAdvanceEvictionGeneration() throws {
    let manager = makeManager()
    manager.initialize(config: testConfig(preloadAhead: 0, preloadBehind: 0))
    try manager.setSources([
      RegisteredSource(id: "visible", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:]),
      RegisteredSource(id: "far", uri: "file:///dev/null", rank: 5, kind: .auto, headers: [:]),
    ])
    try manager.createController(controllerId: 9, sourceId: "far", autoPlay: false, looping: false)

    manager.setVisibleSource("not-registered")

    XCTAssertNotNil(manager.player(for: 9))
  }

  func testTextureFirstFrameMetricIsIdempotent() throws {
    var firstFrameEvents = 0
    let manager = AVPlayerManager(
      onState: { _, _, _ in },
      onReleased: { _, _ in },
      onPosition: { _ in },
      onMetrics: { event in
        if event.firstFrameLatencyMs != nil {
          firstFrameEvents += 1
        }
      },
      onVideoSize: { _ in }
    )
    manager.initialize(config: testConfig())
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 11, sourceId: "clip", autoPlay: false, looping: false)

    manager.markTextureFirstFrame(controllerId: 11)
    manager.markTextureFirstFrame(controllerId: 11)

    XCTAssertEqual(firstFrameEvents, 1)
  }

  func testLoopingCanBeDisabledAfterRuntimeToggle() throws {
    let manager = makeManager()
    manager.initialize(config: testConfig())
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 12, sourceId: "clip", autoPlay: false, looping: false)

    manager.setVolume(controllerId: 12, value: 0.4)
    manager.setMuted(controllerId: 12, value: true)
    manager.setMuted(controllerId: 12, value: false)
    XCTAssertEqual(Double(manager.player(for: 12)?.volume ?? 0), 0.4, accuracy: 0.001)

    manager.setLooping(controllerId: 12, looping: true)
    manager.setLooping(controllerId: 12, looping: false)

    XCTAssertNotNil(manager.player(for: 12)?.currentItem)
    XCTAssertEqual(manager.player(for: 12)?.actionAtItemEnd, .pause)
  }

  func testHLSHeadersAreRejected() {
    let manager = makeManager()
    manager.initialize(config: testConfig())

    XCTAssertThrowsError(
      try manager.setSources([
        RegisteredSource(
          id: "hls",
          uri: "https://example.test/playlist.m3u8",
          rank: 0,
          kind: .hls,
          headers: ["Authorization": "Bearer secret"]
        )
      ])
    ) { error in
      XCTAssertEqual((error as? AVPlayerManager.PlaybackSetupError)?.code, "unsupported_hls_headers")
    }
  }

  func testInvalidURLsAreRejectedAtRegistration() {
    let manager = makeManager()
    manager.initialize(config: testConfig())

    for uri in ["http://", "HTTP://", "not a url with spaces and no scheme", "://broken"] {
      XCTAssertThrowsError(
        try manager.setSources([
          RegisteredSource(id: "bad", uri: uri, rank: 0, kind: .auto, headers: [:])
        ])
      ) { error in
        XCTAssertEqual(
          (error as? AVPlayerManager.PlaybackSetupError)?.code,
          "invalid_url",
          "expected \(uri) to be rejected"
        )
      }
    }
  }

  func testValidURLSchemesAreAccepted() throws {
    let manager = makeManager()
    manager.initialize(config: testConfig())

    XCTAssertNoThrow(
      try manager.setSources([
        RegisteredSource(id: "https", uri: "HTTPS://example.test/a.mp4", rank: 0, kind: .auto, headers: [:]),
        RegisteredSource(id: "file", uri: "file:///tmp/a.mp4", rank: 1, kind: .auto, headers: [:]),
      ])
    )
  }

  func testControllerCreationEmitsPreparingWithoutIdleFlapping() throws {
    var states: [PlaybackStatusMessage] = []
    let manager = AVPlayerManager(
      onState: { _, status, _ in states.append(status) },
      onReleased: { _, _ in },
      onPosition: { _ in },
      onMetrics: { _ in },
      onVideoSize: { _ in }
    )
    manager.initialize(config: testConfig())
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])

    try manager.createController(controllerId: 21, sourceId: "clip", autoPlay: false, looping: false)

    XCTAssertEqual(states, [.preparing])
  }

  func testPlaybackFailureRemainsTerminalAndEmitsOnce() throws {
    var states: [PlaybackStatusMessage] = []
    let manager = AVPlayerManager(
      onState: { _, status, _ in
        states.append(status)
      },
      onReleased: { _, _ in },
      onPosition: { _ in },
      onMetrics: { _ in },
      onVideoSize: { _ in }
    )
    manager.initialize(config: testConfig())
    let source = RegisteredSource(
      id: "broken",
      uri: "https://example.test/broken.mp4",
      rank: 0,
      kind: .auto,
      headers: [:]
    )
    try manager.setSources([source])
    try manager.createController(controllerId: 22, sourceId: source.id, autoPlay: false, looping: false)

    manager.handleResourceFailure(
      identity: source.resourceIdentity,
      error: URLError(.cannotConnectToHost)
    )
    manager.handleResourceFailure(
      identity: source.resourceIdentity,
      error: URLError(.cannotConnectToHost)
    )

    XCTAssertEqual(states.last, .error, "terminal error was overwritten: \(states)")
    XCTAssertEqual(states.filter { $0 == .error }.count, 1)
  }

  func testExpiredSignedRequestFailureDoesNotFailItsReplacement() throws {
    var failures: [Int] = []
    let manager = makeManager(onState: { id, state, _ in
      if state == .error { failures.append(id) }
    })
    manager.initialize(config: config(manageAudioSession: false))
    defer { manager.disposeAll() }
    let old = RegisteredSource(
      id: "clip", uri: "https://example.test/clip.mp4?sig=old", rank: 0,
      kind: .progressive, headers: [:], cacheKey: "stable"
    )
    let fresh = RegisteredSource(
      id: old.id, uri: "https://example.test/clip.mp4?sig=fresh", rank: 0,
      kind: old.kind, headers: old.headers, cacheKey: old.cacheKey
    )
    try manager.setSources([old])
    try manager.createController(controllerId: 71, sourceId: old.id, autoPlay: false, looping: false)
    try manager.setSources([fresh])
    try manager.createController(controllerId: 72, sourceId: fresh.id, autoPlay: false, looping: false)
    manager.handleResourceFailure(identity: old.resourceIdentity, error: URLError(.cannotConnectToHost))
    XCTAssertTrue(failures.isEmpty)
    manager.handleResourceFailure(identity: fresh.resourceIdentity, error: URLError(.cannotConnectToHost))
    XCTAssertEqual(failures, [72])
  }

  func testSignedURLRefreshReleasesControllerButRankOnlyChangesDoNot() throws {
    var released: [Int] = []
    let manager = makeManager(onReleased: { released.append($0) })
    manager.initialize(config: config(manageAudioSession: false))
    defer { manager.disposeAll() }
    let old = RegisteredSource(
      id: "clip", uri: "file:///tmp/old.mp4", rank: 0, kind: .progressive,
      headers: [:], cacheKey: "stable"
    )
    try manager.setSources([old])
    try manager.createController(controllerId: 40, sourceId: "clip", autoPlay: false, looping: false)
    try manager.setSources([
      RegisteredSource(id: old.id, uri: old.uri, rank: 1, kind: old.kind, headers: [:], cacheKey: old.cacheKey)
    ])
    XCTAssertNotNil(manager.player(for: 40))
    try manager.setSources([
      RegisteredSource(id: old.id, uri: "file:///tmp/new.mp4", rank: 1, kind: old.kind, headers: [:], cacheKey: old.cacheKey)
    ])
    XCTAssertNil(manager.player(for: 40))
    XCTAssertEqual(released, [40])
  }

  func testSignedURLRefreshDiscardsPreparedAsset() throws {
    var loadedURL: URL?
    let manager = makeManager(loadLoopAsset: { asset, _ in
      loadedURL = (asset as? AVURLAsset)?.url
    })
    manager.initialize(config: config(manageAudioSession: false))
    defer { manager.disposeAll() }
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///tmp/old.mp4", rank: 0, kind: .progressive, headers: [:], cacheKey: "stable")
    ])
    drainMainQueue()
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///tmp/new.mp4", rank: 0, kind: .progressive, headers: [:], cacheKey: "stable")
    ])
    try manager.createController(controllerId: 41, sourceId: "clip", autoPlay: false, looping: true)
    XCTAssertEqual(loadedURL?.absoluteString, "file:///tmp/new.mp4")
    XCTAssertNil(manager.player(for: 41)?.currentItem)
  }

  func testLoopMetadataFailureIsTypedAndTerminal() throws {
    var completion: ((Result<CMTime, Error>) -> Void)?
    var errors: [PlaybackErrorMessage] = []
    let manager = makeManager(
      onState: { _, _, error in if let error { errors.append(error) } },
      loadLoopAsset: { _, callback in completion = callback }
    )
    manager.initialize(config: config(manageAudioSession: false))
    defer { manager.disposeAll() }
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 42, sourceId: "clip", autoPlay: true, looping: true)
    XCTAssertNotNil(completion)
    XCTAssertNil(manager.player(for: 42)?.currentItem)
    completion?(.failure(URLError(.timedOut)))
    drainMainQueue()
    manager.play(controllerId: 42)
    XCTAssertEqual(errors.map(\.code), ["network_failed"])
    XCTAssertEqual(manager.player(for: 42)?.rate, 0)
  }

  func testLoopRejectsZeroAndIndefiniteDurationBeforeCreatingLooper() throws {
    for duration in [CMTime.zero, .indefinite, .invalid, CMTime(value: -1, timescale: 1)] {
      var errors: [PlaybackErrorMessage] = []
      let manager = makeManager(
        onState: { _, _, error in if let error { errors.append(error) } },
        loadLoopAsset: { _, callback in callback(.success(duration)) }
      )
      manager.initialize(config: config(manageAudioSession: false))
      try manager.setSources([
        RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
      ])
      try manager.createController(controllerId: 43, sourceId: "clip", autoPlay: true, looping: true)
      drainMainQueue()
      XCTAssertEqual(errors.map(\.code), ["media_malformed"])
      XCTAssertNil(manager.player(for: 43)?.currentItem)
      XCTAssertEqual(manager.player(for: 43)?.rate, 0)
      manager.disposeAll()
    }
  }

  func testLoadedLoopRespectsPauseAndBackgroundCommandsBeforeCompletion() throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_clip.mp4")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "local video fixture unavailable")
    for pauseBeforeCompletion in [true, false] {
      let loaded = expectation(description: "loop metadata loaded")
      var finish: (() -> Void)?
      var errors: [PlaybackErrorMessage] = []
      let manager = makeManager(
        onState: { _, _, error in if let error { errors.append(error) } },
        loadLoopAsset: { asset, callback in
          AVPlayerManager.loadLoopAssetMetadata(asset) { result in
            DispatchQueue.main.async {
              finish = { callback(result) }
              loaded.fulfill()
            }
          }
        }
      )
      manager.initialize(config: config(manageAudioSession: false))
      NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
      try manager.setSources([
        RegisteredSource(id: "clip", uri: fixture.absoluteString, rank: 0, kind: .progressive, headers: [:])
      ])
      try manager.createController(controllerId: 49, sourceId: "clip", autoPlay: true, looping: true)
      if pauseBeforeCompletion {
        manager.pause(controllerId: 49)
      } else {
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        manager.play(controllerId: 49)
      }
      wait(for: [loaded], timeout: 5)
      finish?()
      drainMainQueue()
      XCTAssertTrue(errors.isEmpty)
      XCTAssertNotNil(manager.player(for: 49)?.currentItem)
      XCTAssertEqual(manager.player(for: 49)?.rate, 0)
      manager.disposeAll()
      NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    }
  }

  func testSeekDuringLoopMetadataLoadingUsesTheLatestPosition() throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_clip.mp4")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "local video fixture unavailable")
    let loaded = expectation(description: "loop metadata loaded")
    var finish: (() -> Void)?
    let manager = makeManager(loadLoopAsset: { asset, callback in
      AVPlayerManager.loadLoopAssetMetadata(asset) { result in
        DispatchQueue.main.async {
          finish = { callback(result) }
          loaded.fulfill()
        }
      }
    })
    manager.initialize(config: config(manageAudioSession: false))
    defer { manager.disposeAll() }
    try manager.setSources([
      RegisteredSource(id: "clip", uri: fixture.absoluteString, rank: 0, kind: .progressive, headers: [:])
    ])
    try manager.createController(controllerId: 73, sourceId: "clip", autoPlay: false, looping: true)
    manager.seekTo(controllerId: 73, positionMs: 100)
    manager.seekTo(controllerId: 73, positionMs: 250)
    wait(for: [loaded], timeout: 5)
    finish?()
    let seeked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard let seconds = manager.player(for: 73)?.currentTime().seconds else { return false }
      return seconds.isFinite && abs(seconds - 0.25) < 0.02
    }, object: nil)
    wait(for: [seeked], timeout: 5)
    XCTAssertEqual(manager.player(for: 73)?.rate, 0)
  }

  func testPendingLoopCompletionCannotReviveReinitializedControllerWithSameID() throws {
    var completions: [(Result<CMTime, Error>) -> Void] = []
    var errors = 0
    let manager = makeManager(
      onState: { _, _, error in if error != nil { errors += 1 } },
      loadLoopAsset: { _, callback in completions.append(callback) }
    )
    let settings = config(manageAudioSession: false)
    manager.initialize(config: settings)
    defer { manager.disposeAll() }
    let source = RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    try manager.setSources([source])
    try manager.createController(controllerId: 44, sourceId: "clip", autoPlay: true, looping: true)
    manager.initialize(config: settings)
    try manager.setSources([source])
    try manager.createController(controllerId: 44, sourceId: "clip", autoPlay: false, looping: true)
    completions[0](.success(CMTime(value: 1, timescale: 1)))
    drainMainQueue()
    XCTAssertEqual(errors, 0)
    XCTAssertNil(manager.player(for: 44)?.currentItem)
    XCTAssertEqual(manager.player(for: 44)?.rate, 0)
  }

  func testStaleLoopToggleCompletionCannotOverrideLatestLoopOrPause() throws {
    var completions: [(Result<CMTime, Error>) -> Void] = []
    var errors = 0
    let manager = makeManager(
      onState: { _, _, error in if error != nil { errors += 1 } },
      loadLoopAsset: { _, callback in completions.append(callback) }
    )
    manager.initialize(config: config(manageAudioSession: false))
    defer { manager.disposeAll() }
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 45, sourceId: "clip", autoPlay: true, looping: true)
    manager.setLooping(controllerId: 45, looping: false)
    manager.setLooping(controllerId: 45, looping: true)
    manager.pause(controllerId: 45)
    completions[0](.success(CMTime(value: 1, timescale: 1)))
    drainMainQueue()
    XCTAssertEqual(errors, 0)
    XCTAssertNil(manager.player(for: 45)?.currentItem)
    XCTAssertEqual(manager.player(for: 45)?.rate, 0)
  }

  func testBackgroundPausesWaitingPlayersAndHonoursManualPause() throws {
    let manager = makeManager()
    manager.initialize(config: config(manageAudioSession: false))
    defer {
      manager.disposeAll()
      NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "https://example.test/slow.mp4", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 46, sourceId: "clip", autoPlay: true, looping: false)
    let player = try XCTUnwrap(manager.player(for: 46))
    XCTAssertEqual(player.timeControlStatus, .waitingToPlayAtSpecifiedRate)
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertEqual(player.timeControlStatus, .paused)
    manager.play(controllerId: 46)
    XCTAssertEqual(player.rate, 0)
    manager.pause(controllerId: 46)
    NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(player.timeControlStatus, .paused)
  }

  func testAutoPlayCreatedInBackgroundWaitsForForeground() throws {
    let manager = makeManager()
    manager.initialize(config: config(manageAudioSession: false))
    defer {
      manager.disposeAll()
      NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "https://example.test/slow.mp4", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 47, sourceId: "clip", autoPlay: true, looping: false)
    XCTAssertEqual(manager.player(for: 47)?.rate, 0)
    NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    XCTAssertEqual(manager.player(for: 47)?.timeControlStatus, .waitingToPlayAtSpecifiedRate)
  }

  func testCurrentItemReplacementReattachesStatusObservation() throws {
    var preparingCount = 0
    let manager = makeManager(onState: { _, status, _ in
      if status == .preparing { preparingCount += 1 }
    })
    manager.initialize(config: config(manageAudioSession: false))
    defer { manager.disposeAll() }
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 48, sourceId: "clip", autoPlay: false, looping: false)
    let player = try XCTUnwrap(manager.player(for: 48) as? AVQueuePlayer)
    let first = preparingCount
    player.removeAllItems()
    player.insert(AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")), after: nil)
    XCTAssertEqual(preparingCount, first + 1)
  }

  func testOwnedAudioSessionIsDeactivatedOnResetAndOwnershipTransferOnly() {
    var activations: [(Bool, AVAudioSession.SetActiveOptions)] = []
    let manager = makeManager(setAudioSessionActive: { activations.append(($0, $1)) })
    manager.initialize(config: config())
    XCTAssertEqual(activations.map { $0.0 }, [true])
    manager.initialize(config: config())
    XCTAssertEqual(activations.map { $0.0 }, [true, false, true])
    XCTAssertTrue(activations[1].1.contains(.notifyOthersOnDeactivation))
    manager.applyAudioPolicy(AudioPolicyMessage(
      muted: true, volume: 1, handleAudioFocus: false, manageAudioSession: false
    ))
    XCTAssertEqual(activations.map { $0.0 }, [true, false, true, false])
    XCTAssertTrue(activations[3].1.contains(.notifyOthersOnDeactivation))
    manager.disposeAll()
    XCTAssertEqual(activations.count, 4)
  }

  func testDisposeDeactivatesOwnedSessionExactlyOnce() {
    var activations: [(Bool, AVAudioSession.SetActiveOptions)] = []
    let manager = makeManager(setAudioSessionActive: { activations.append(($0, $1)) })
    manager.initialize(config: config())
    manager.disposeAll()
    manager.disposeAll()
    XCTAssertEqual(activations.map { $0.0 }, [true, false])
    XCTAssertTrue(activations.last?.1.contains(.notifyOthersOnDeactivation) == true)
  }

  func testHostOwnedAudioSessionIsNeverActivatedOrDeactivated() {
    var activations: [Bool] = []
    let manager = makeManager(setAudioSessionActive: { active, _ in activations.append(active) })
    manager.initialize(config: config(manageAudioSession: false))
    manager.disposeAll()
    XCTAssertTrue(activations.isEmpty)
  }

  func testNewSessionResynchronizesLifecycleAfterObservationWasStopped() throws {
    for initialState in [UIApplication.State.active, .background] {
      var applicationState = initialState
      let manager = makeManager(applicationState: { applicationState })
      let settings = config(manageAudioSession: false)
      manager.initialize(config: settings)
      manager.disposeAll()
      applicationState = initialState == .active ? .background : .active
      NotificationCenter.default.post(
        name: applicationState == .background
          ? UIApplication.didEnterBackgroundNotification
          : UIApplication.willEnterForegroundNotification,
        object: nil
      )
      manager.initialize(config: settings)
      try manager.setSources([
        RegisteredSource(id: "clip", uri: "https://example.test/slow.mp4", rank: 0, kind: .auto, headers: [:])
      ])
      try manager.createController(controllerId: 81, sourceId: "clip", autoPlay: true, looping: false)
      let player = try XCTUnwrap(manager.player(for: 81))
      if applicationState == .background {
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.timeControlStatus, .paused)
      } else {
        XCTAssertNotEqual(player.timeControlStatus, .paused)
      }
      manager.disposeAll()
    }
  }

  func testUnmuteClearsNativeMuteFlagForControllerAndPolicyChanges() throws {
    let manager = makeManager()
    manager.initialize(config: config(manageAudioSession: false, muted: true))
    defer { manager.disposeAll() }
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 90, sourceId: "clip", autoPlay: false, looping: false)
    let player = try XCTUnwrap(manager.player(for: 90))
    XCTAssertTrue(player.isMuted)

    manager.setVolume(controllerId: 90, value: 0.4)
    manager.setMuted(controllerId: 90, value: false)
    XCTAssertFalse(player.isMuted)
    XCTAssertEqual(Double(player.volume), 0.4, accuracy: 0.001)
    manager.setMuted(controllerId: 90, value: true)
    XCTAssertTrue(player.isMuted)
    XCTAssertEqual(player.volume, 0)
    manager.setMuted(controllerId: 90, value: false)
    XCTAssertFalse(player.isMuted)
    XCTAssertEqual(Double(player.volume), 0.4, accuracy: 0.001)

    let policy = { (muted: Bool) in
      AudioPolicyMessage(muted: muted, volume: 0.6, handleAudioFocus: false, manageAudioSession: false)
    }
    manager.applyAudioPolicy(policy(true))
    XCTAssertTrue(player.isMuted)
    manager.applyAudioPolicy(policy(false))
    XCTAssertFalse(player.isMuted)
    XCTAssertEqual(Double(player.volume), 0.6, accuracy: 0.001)

    manager.applyAudioPolicy(policy(true))
    manager.disposeController(controllerId: 90)
    manager.applyAudioPolicy(policy(false))
    try manager.createController(controllerId: 91, sourceId: "clip", autoPlay: false, looping: false)
    let pooled = try XCTUnwrap(manager.player(for: 91))
    XCTAssertTrue(pooled === player)
    XCTAssertFalse(pooled.isMuted)
    XCTAssertEqual(Double(pooled.volume), 0.6, accuracy: 0.001)
  }

  func testTextureAttachmentEmitsPausedPositionsUntilDetachedOrReleased() throws {
    var positions: [Int64: Int] = [:]
    let manager = AVPlayerManager(
      onState: { _, _, _ in },
      onReleased: { _, _ in },
      onPosition: { positions[$0.controllerId, default: 0] += 1 },
      onMetrics: { _ in },
      onVideoSize: { _ in },
      setAudioSessionActive: { _, _ in }
    )
    var settings = config(manageAudioSession: false)
    settings.positionUpdateIntervalMs = 50
    manager.initialize(config: settings)
    defer { manager.disposeAll() }
    try manager.setSources([
      RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])
    ])
    try manager.createController(controllerId: 92, sourceId: "clip", autoPlay: false, looping: false)

    pumpRunLoop(0.2)
    XCTAssertNil(positions[92], "offscreen paused players stay silent")

    manager.setTextureAttached(true, controllerId: 92)
    manager.seekTo(controllerId: 92, positionMs: 0)
    pumpRunLoop(0.2)
    XCTAssertGreaterThan(positions[92] ?? 0, 0)

    manager.setTextureAttached(false, controllerId: 92)
    pumpRunLoop(0.1)
    positions[92] = 0
    pumpRunLoop(0.2)
    XCTAssertEqual(positions[92], 0)

    manager.setTextureAttached(true, controllerId: 92)
    manager.disposeController(controllerId: 92)
    manager.setTextureAttached(true, controllerId: 92)
    try manager.createController(controllerId: 93, sourceId: "clip", autoPlay: false, looping: false)
    pumpRunLoop(0.2)
    XCTAssertNil(positions[93])
  }

  private func pumpRunLoop(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func makeManager(
    onReleased: @escaping (Int) -> Void = { _ in },
    onState: @escaping AVPlayerManager.StateCallback = { _, _, _ in },
    loadLoopAsset: @escaping AVPlayerManager.LoopAssetLoader = AVPlayerManager.loadLoopAssetMetadata,
    applicationState: @escaping () -> UIApplication.State = { UIApplication.shared.applicationState },
    setAudioSessionActive: @escaping (Bool, AVAudioSession.SetActiveOptions) throws -> Void = {
      try AVAudioSession.sharedInstance().setActive($0, options: $1)
    }
  ) -> AVPlayerManager {
    AVPlayerManager(
      onState: onState,
      onReleased: { controllerId, _ in onReleased(controllerId) },
      onPosition: { _ in },
      onMetrics: { _ in },
      onVideoSize: { _ in },
      loadLoopAsset: loadLoopAsset,
      applicationState: applicationState,
      setAudioSessionActive: setAudioSessionActive
    )
  }

  private func drainMainQueue() {
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  private func testConfig(
    preloadAhead: Int64 = 2,
    preloadBehind: Int64 = 1
  ) -> FeedPlayerConfigMessage {
    FeedPlayerConfigMessage(
      maxActivePlayers: 3,
      preloadAhead: preloadAhead,
      preloadBehind: preloadBehind,
      maxConcurrentPreloads: 2,
      positionUpdateIntervalMs: 200,
      renderMode: .platformView,
      cache: CachePolicyMessage(enabled: false, maxBytes: 0),
      audio: AudioPolicyMessage(muted: true, volume: 1, handleAudioFocus: false, manageAudioSession: true)
    )
  }
}

private final class RecoveryTestItem: AVPlayerItem {
  private var empty = true
  private var ranges: [NSValue] = []
  override var status: AVPlayerItem.Status { .readyToPlay }
  override var duration: CMTime { CMTime(seconds: 10, preferredTimescale: 1000) }
  override var isPlaybackBufferEmpty: Bool { empty }
  override var loadedTimeRanges: [NSValue] { ranges }

  func setBuffer(seconds: Double, empty: Bool) {
    willChangeValue(forKey: "loadedTimeRanges")
    ranges = seconds > 0 ? [NSValue(timeRange: CMTimeRange(
      start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 1000)
    ))] : []
    didChangeValue(forKey: "loadedTimeRanges")
    willChangeValue(forKey: "playbackBufferEmpty")
    self.empty = empty
    didChangeValue(forKey: "playbackBufferEmpty")
  }
}

private final class RecoveryTestPlayer: AVQueuePlayer {
  let testItem = RecoveryTestItem(url: URL(fileURLWithPath: "/dev/null"))
  private var selectedItem: AVPlayerItem?
  private var playbackStatus: AVPlayer.TimeControlStatus = .paused
  private var playbackRate: Float = 0
  var starts: [Float] = []
  var position: CMTime = .zero
  var pendingSeeks: [(time: CMTime, completion: (Bool) -> Void)] = []
  override var currentItem: AVPlayerItem? { selectedItem }
  override var timeControlStatus: AVPlayer.TimeControlStatus { playbackStatus }
  override var rate: Float {
    get { playbackRate }
    set { playbackRate = newValue }
  }
  override func currentTime() -> CMTime { position }
  override func seek(
    to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
    completionHandler: @escaping (Bool) -> Void
  ) {
    pendingSeeks.append((time, completionHandler))
  }
  func finishSeek(_ index: Int, finished: Bool = true) {
    let seek = pendingSeeks[index]
    if finished { position = seek.time }
    seek.completion(finished)
  }
  override func insert(_ item: AVPlayerItem, after afterItem: AVPlayerItem?) {
    willChangeValue(forKey: "currentItem")
    selectedItem = testItem
    didChangeValue(forKey: "currentItem")
  }
  override func removeAllItems() {
    willChangeValue(forKey: "currentItem")
    selectedItem = nil
    didChangeValue(forKey: "currentItem")
  }
  override func play() { playImmediately(atRate: 1) }
  override func playImmediately(atRate rate: Float) {
    starts.append(rate)
    playbackRate = rate
    transition(to: .playing)
  }
  override func pause() {
    playbackRate = 0
    transition(to: .paused)
  }
  private func transition(to status: AVPlayer.TimeControlStatus) {
    guard playbackStatus != status else { return }
    willChangeValue(forKey: "timeControlStatus")
    playbackStatus = status
    didChangeValue(forKey: "timeControlStatus")
  }
}

final class ManualPlaybackRecoveryTests: XCTestCase {
  private func manager(
    player: RecoveryTestPlayer,
    onState: @escaping AVPlayerManager.StateCallback = { _, _, _ in },
    onMetrics: @escaping AVPlayerManager.MetricsCallback = { _ in },
    positionIntervalMs: Int64 = 200,
    loadLoopAsset: @escaping AVPlayerManager.LoopAssetLoader = AVPlayerManager.loadLoopAssetMetadata
  ) -> AVPlayerManager {
    let manager = AVPlayerManager(
      onState: onState, onReleased: { _, _ in }, onPosition: { _ in },
      onMetrics: onMetrics, onVideoSize: { _ in }, makePlayer: { player },
      loadLoopAsset: loadLoopAsset, applicationState: { .active }
    )
    manager.initialize(config: FeedPlayerConfigMessage(
      maxActivePlayers: 1, preloadAhead: 0, preloadBehind: 0, maxConcurrentPreloads: 1,
      positionUpdateIntervalMs: positionIntervalMs, renderMode: .platformView,
      cache: CachePolicyMessage(enabled: false, maxBytes: 1024),
      audio: AudioPolicyMessage(muted: true, volume: 1, handleAudioFocus: false, manageAudioSession: false)
    ))
    return manager
  }

  private func create(_ manager: AVPlayerManager, custom: Bool = true) throws {
    try manager.setSources([
      RegisteredSource(
        id: "clip", uri: "https://example.invalid/video.mp4", rank: 0,
        kind: .progressive, headers: custom ? ["Authorization": "test"] : [:]
      )
    ])
    try manager.createController(controllerId: 82, sourceId: "clip", autoPlay: false, looping: false)
  }

  func testCustomLoadingResumesAfterRefillAtRequestedRateAndCountsOneStall() throws {
    let player = RecoveryTestPlayer()
    var rebuffers: [Int64] = []
    let manager = manager(player: player, onMetrics: { rebuffers.append($0.rebufferCount) })
    defer { manager.disposeAll() }
    try create(manager)
    XCTAssertFalse(player.automaticallyWaitsToMinimizeStalling)
    manager.setPlaybackSpeed(controllerId: 82, speed: 0.5)
    manager.play(controllerId: 82)
    XCTAssertTrue(player.starts.isEmpty)
    player.testItem.setBuffer(seconds: 1, empty: false)
    XCTAssertEqual(player.starts, [0.5])
    player.testItem.setBuffer(seconds: 0, empty: true)
    player.pause()
    NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: player.testItem)
    XCTAssertEqual(rebuffers.max(), 1)
    player.testItem.setBuffer(seconds: 0.1, empty: false)
    XCTAssertEqual(player.starts.count, 1)
    player.testItem.setBuffer(seconds: 1, empty: false)
    XCTAssertEqual(player.starts, [0.5, 0.5])
    XCTAssertEqual(rebuffers.max(), 1)
  }

  func testBufferRefillCannotOverridePauseBackgroundReleaseOrFailure() throws {
    for action in ["pause", "background", "release", "failure"] {
      let player = RecoveryTestPlayer()
      let manager = manager(player: player)
      try create(manager)
      manager.play(controllerId: 82)
      switch action {
      case "pause": manager.pause(controllerId: 82)
      case "background":
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
      case "release": manager.disposeController(controllerId: 82)
      default:
        let source = RegisteredSource(
          id: "clip", uri: "https://example.invalid/video.mp4", rank: 0,
          kind: .progressive, headers: ["Authorization": "test"]
        )
        manager.handleResourceFailure(identity: source.resourceIdentity, error: URLError(.networkConnectionLost))
      }
      player.testItem.setBuffer(seconds: 1, empty: false)
      XCTAssertTrue(player.starts.isEmpty, action)
      if action == "background" {
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(player.starts, [1])
      }
      manager.disposeAll()
    }
  }

  func testReadyReplacementReportsSynchronousPlaybackAndSubsequentStalls() throws {
    let player = RecoveryTestPlayer()
    var states: [PlaybackStatusMessage] = []
    var rebuffers: [Int64] = []
    let manager = manager(
      player: player, onState: { _, state, _ in states.append(state) },
      onMetrics: { rebuffers.append($0.rebufferCount) }
    )
    defer { manager.disposeAll() }
    try create(manager)
    manager.play(controllerId: 82)
    XCTAssertEqual(states.last, .buffering)
    player.removeAllItems()
    player.testItem.setBuffer(seconds: 1, empty: false)
    player.insert(player.testItem, after: nil)
    XCTAssertEqual(player.starts, [1])
    XCTAssertEqual(states.last, .playing)
    player.testItem.setBuffer(seconds: 0, empty: true)
    player.pause()
    XCTAssertEqual(states.last, .buffering)
    XCTAssertEqual(rebuffers.max(), 1)
  }

  func testReplaySeekCompletionResumesWithoutBufferEventsOrPositionTicks() throws {
    let player = RecoveryTestPlayer()
    let manager = manager(player: player, positionIntervalMs: 3_600_000)
    defer { manager.disposeAll() }
    try create(manager)
    player.position = player.testItem.duration
    player.testItem.setBuffer(seconds: 10, empty: false)
    manager.seekTo(controllerId: 82, positionMs: 0)
    manager.setPlaybackSpeed(controllerId: 82, speed: 0.5)
    manager.play(controllerId: 82)
    XCTAssertTrue(player.starts.isEmpty)
    XCTAssertEqual(player.pendingSeeks.count, 1)
    player.finishSeek(0)
    XCTAssertEqual(player.starts, [0.5])
  }

  func testOnlyLatestSeekCanResumeAndBufferEventsCannotResumeAnInFlightSeek() throws {
    let player = RecoveryTestPlayer()
    let manager = manager(player: player, positionIntervalMs: 3_600_000)
    defer { manager.disposeAll() }
    try create(manager)
    manager.play(controllerId: 82)
    manager.seekTo(controllerId: 82, positionMs: 1000)
    player.testItem.setBuffer(seconds: 10, empty: false)
    XCTAssertTrue(player.starts.isEmpty)
    manager.seekTo(controllerId: 82, positionMs: 2000)
    player.finishSeek(0)
    XCTAssertTrue(player.starts.isEmpty)
    player.finishSeek(1)
    XCTAssertEqual(player.starts, [1])
    XCTAssertEqual(player.position, CMTime(seconds: 2, preferredTimescale: 1000))
  }

  func testSeekCompletionHonoursPauseBackgroundReleaseFailureAndInterruption() throws {
    for action in ["pause", "background", "release", "failure", "interrupted"] {
      let player = RecoveryTestPlayer()
      let manager = manager(player: player, positionIntervalMs: 3_600_000)
      try create(manager)
      manager.play(controllerId: 82)
      manager.seekTo(controllerId: 82, positionMs: 2000)
      switch action {
      case "pause": manager.pause(controllerId: 82)
      case "background":
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
      case "release": manager.disposeController(controllerId: 82)
      case "failure":
        let source = RegisteredSource(
          id: "clip", uri: "https://example.invalid/video.mp4", rank: 0,
          kind: .progressive, headers: ["Authorization": "test"]
        )
        manager.handleResourceFailure(identity: source.resourceIdentity, error: URLError(.networkConnectionLost))
      default: break
      }
      player.testItem.setBuffer(seconds: 10, empty: false)
      XCTAssertTrue(player.starts.isEmpty, action)
      player.finishSeek(0, finished: action != "interrupted")
      XCTAssertTrue(player.starts.isEmpty, action)
      if action == "background" {
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(player.starts, [1])
      }
      manager.disposeAll()
    }
  }

  func testLoopChangesPreserveTheLatestSeekAndIgnoreItsSupersededCompletion() throws {
    let player = RecoveryTestPlayer()
    var loopCompletions: [(Result<CMTime, Error>) -> Void] = []
    let manager = manager(
      player: player, positionIntervalMs: 3_600_000,
      loadLoopAsset: { _, completion in loopCompletions.append(completion) }
    )
    defer { manager.disposeAll() }
    try create(manager)
    manager.play(controllerId: 82)
    manager.seekTo(controllerId: 82, positionMs: 3000)
    manager.setLooping(controllerId: 82, looping: true)
    manager.setLooping(controllerId: 82, looping: false)
    XCTAssertEqual(player.pendingSeeks.count, 2)
    XCTAssertEqual(player.pendingSeeks[1].time, CMTime(seconds: 3, preferredTimescale: 1000))
    player.testItem.setBuffer(seconds: 10, empty: false)
    player.finishSeek(0)
    XCTAssertTrue(player.starts.isEmpty)
    player.finishSeek(1)
    let drained = expectation(description: "loop seek completion")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 1)
    XCTAssertEqual(player.starts, [1])
    loopCompletions[0](.success(player.testItem.duration))
    let staleDrained = expectation(description: "stale loop completion")
    DispatchQueue.main.async { staleDrained.fulfill() }
    wait(for: [staleDrained], timeout: 1)
    XCTAssertEqual(player.starts, [1])
  }

  func testNonCustomLoadingKeepsNativeAutomaticWaiting() throws {
    let player = RecoveryTestPlayer()
    let manager = manager(player: player)
    defer { manager.disposeAll() }
    try create(manager, custom: false)
    XCTAssertTrue(player.automaticallyWaitsToMinimizeStalling)
  }

  func testResumeBufferRequiresDataAtCurrentPositionAndAllowsShortTail() {
    func ready(_ start: Double, _ length: Double, position: Double, duration: CMTime) -> Bool {
      AVPlayerManager.hasResumeBuffer(
        position: CMTime(seconds: position, preferredTimescale: 1000), duration: duration,
        ranges: [CMTimeRange(
          start: CMTime(seconds: start, preferredTimescale: 1000),
          duration: CMTime(seconds: length, preferredTimescale: 1000)
        )]
      )
    }
    let duration = CMTime(seconds: 10, preferredTimescale: 1000)
    XCTAssertFalse(ready(2, 1, position: 0, duration: duration))
    XCTAssertFalse(ready(0, 0.1, position: 0, duration: duration))
    XCTAssertTrue(ready(0, 0.25, position: 0, duration: duration))
    XCTAssertTrue(ready(9.9, 0.1, position: 9.9, duration: duration))
    XCTAssertFalse(ready(9.9, 0.1, position: 10, duration: duration))
    XCTAssertTrue(ready(0, 0.5, position: 0, duration: .indefinite))
  }
}

final class DroppedFrameAccumulatorTests: XCTestCase {
  func testAccumulatesDeltasAcrossReplicasWithoutDoubleCountingReusedItems() {
    let accumulator = AVPlayerManager.DroppedFrameAccumulator()
    let first = NSObject()
    let second = NSObject()
    accumulator.record(item: first, droppedFrames: 4)
    accumulator.record(item: first, droppedFrames: 7)
    accumulator.record(item: second, droppedFrames: 3)
    accumulator.record(item: first, droppedFrames: 7)
    XCTAssertEqual(accumulator.total, 10)
    accumulator.record(item: first, droppedFrames: 9)
    XCTAssertEqual(accumulator.total, 12)
    accumulator.record(item: second, droppedFrames: 1)
    XCTAssertEqual(accumulator.total, 13)
  }

  func testTrackingDoesNotRetainRetiredLooperItems() {
    let accumulator = AVPlayerManager.DroppedFrameAccumulator()
    weak var retired: NSObject?
    autoreleasepool {
      let item = NSObject()
      retired = item
      accumulator.record(item: item, droppedFrames: 5)
    }
    XCTAssertNil(retired)
    let next = NSObject()
    accumulator.record(item: next, droppedFrames: 2)
    XCTAssertEqual(accumulator.total, 7)
  }
}

final class VideoOutputTextureTests: XCTestCase {
  func testFirstPixelCallbackFiresOnce() {
    let texture = VideoOutputTexture(player: AVPlayer())
    var firstPixels = 0
    var frames = 0
    texture.onFirstPixel = { firstPixels += 1 }
    texture.onFrameAvailable = { _ in frames += 1 }

    texture.notifyFrameAvailable()
    texture.notifyFrameAvailable()

    XCTAssertEqual(firstPixels, 1)
    XCTAssertEqual(frames, 2)

    texture.attach(to: AVPlayer()) { firstPixels += 1 }
    texture.notifyFrameAvailable()

    XCTAssertEqual(firstPixels, 2)
    XCTAssertEqual(frames, 3)
    texture.detachOutput()
  }

  func testDisplayLinkDoesNotRetainTexture() {
    weak var weakTexture: VideoOutputTexture?

    autoreleasepool {
      let texture = VideoOutputTexture(player: AVPlayer())
      weakTexture = texture
    }

    XCTAssertNil(weakTexture)
  }
}

final class NativeVideoRenderViewTests: XCTestCase {
  func testFitMapsToPlayerLayerGravity() {
    let view = NativeVideoRenderView()

    view.setFit("cover")
    XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspectFill)

    view.setFit("contain")
    XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspect)

    view.setFit("fill")
    XCTAssertEqual(view.playerLayer.videoGravity, .resize)

    for fit in ["fitWidth", "fitHeight", "none", "scaleDown", "unknown"] {
      view.setFit(fit)
      XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspect)
    }
  }
}

private final class NoNetworkProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
  }
  override func stopLoading() {}
}

final class CacheRegressionTests: XCTestCase {
  private var fixtureRoot: URL!
  private var cache: MediaDiskCache!
  private var loader: CachingResourceLoader!
  private var loaderQueue: DispatchQueue!

  override func setUpWithError() throws {
    fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false)
    cache = MediaDiskCache(rootURL: fixtureRoot.appendingPathComponent("cache", isDirectory: true))
    cache.configure(enabled: true, maxBytes: 16 * 1024 * 1024)
    cache.waitForPendingWorkForTesting()
    loaderQueue = DispatchQueue(label: "cache-regression.\(UUID().uuidString)")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NoNetworkProtocol.self]
    loader = CachingResourceLoader(
      sessionConfiguration: configuration,
      queue: loaderQueue,
      cache: cache
    )
  }

  override func tearDownWithError() throws {
    loader?.shutdown()
    loader = nil
    cache?.configure(enabled: false, maxBytes: 16 * 1024 * 1024)
    cache?.waitForPendingWorkForTesting()
    cache = nil
    if let fixtureRoot {
      try FileManager.default.removeItem(at: fixtureRoot)
    }
    fixtureRoot = nil
  }

  private func assertContextCount(
    _ expected: Int, file: StaticString = #filePath, line: UInt = #line
  ) {
    let ready = expectation(description: "context count \(expected)")
    loader.contextCountForTesting { count in
      XCTAssertEqual(count, expected, file: file, line: line)
      ready.fulfill()
    }
    wait(for: [ready], timeout: 2)
  }

  func testOldContextReleaseDoesNotRemoveNewPreparation() throws {
    let uri = "https://example.invalid/private.mp4?signature=one"
    let old = try XCTUnwrap(loader.prepareURL(
      for: uri, headers: ["Authorization": "Bearer private"], cacheKey: "stable"
    ))
    let fresh = try XCTUnwrap(loader.prepareURL(
      for: uri, headers: ["authorization": "Bearer private"], cacheKey: "stable"
    ))
    XCTAssertNotEqual(old, fresh)
    XCTAssertEqual(CachingResourceLoader.identity(from: old), CachingResourceLoader.identity(from: fresh))
    XCTAssertEqual(CachingResourceLoader.originalURL(from: fresh)?.absoluteString, uri)
    assertContextCount(2)
    loader.releaseURL(old)
    assertContextCount(1)
    loader.releaseURL(old)
    assertContextCount(1)
    loader.releaseURL(fresh)
    assertContextCount(0)
  }

  func testCancelAllAndIdentityCancellationPreserveLiveContexts() throws {
    let url = try XCTUnwrap(loader.prepareURL(
      for: "https://example.invalid/private.mp4",
      headers: ["Authorization": "Bearer private"], cacheKey: "stable"
    ))
    let identity = try XCTUnwrap(CachingResourceLoader.identity(from: url))
    assertContextCount(1)
    let canceled = expectation(description: "cancel all completed")
    loader.cancelAll { canceled.fulfill() }
    wait(for: [canceled], timeout: 2)
    assertContextCount(1)
    let identityCanceled = expectation(description: "identity cancellation completed")
    loader.cancel(identities: [identity]) { identityCanceled.fulfill() }
    wait(for: [identityCanceled], timeout: 2)
    assertContextCount(1)
    loader.releaseURL(url)
    assertContextCount(0)
  }

  func testAssetDeallocationReleasesContext() throws {
    weak var weakAsset: AVURLAsset?
    try autoreleasepool {
      let asset = try XCTUnwrap(loader.prepareAsset(
        for: "https://example.invalid/private.mp4",
        headers: ["Authorization": "Bearer private"]
      ))
      weakAsset = asset
      withExtendedLifetime(asset) {
        assertContextCount(1)
      }
    }
    XCTAssertNil(weakAsset)
    assertContextCount(0)
  }

  func testRepeatedAssetDeallocationBoundsContexts() throws {
    for _ in 0..<64 {
      try autoreleasepool {
        let asset = try XCTUnwrap(loader.prepareAsset(
          for: "https://example.invalid/private.mp4",
          headers: ["Authorization": "Bearer private"], cacheKey: "stable"
        ))
        withExtendedLifetime(asset) {}
      }
    }
    assertContextCount(0)
  }

  func testPreparationReturnsWhileLoaderQueueIsSuspended() {
    let returned = DispatchSemaphore(value: 0)
    let currentLoader = loader!
    loaderQueue.suspend()
    var suspended = true
    defer {
      if suspended {
        loaderQueue.resume()
      }
    }
    DispatchQueue.global().async {
      let url = currentLoader.prepareURL(
        for: "https://example.invalid/private.mp4",
        headers: ["Authorization": "Bearer private"]
      )
      XCTAssertNotNil(url)
      if let url {
        currentLoader.releaseURL(url)
      }
      returned.signal()
    }
    let result = returned.wait(timeout: .now() + 1)
    loaderQueue.resume()
    suspended = false
    XCTAssertEqual(result, .success, "prepareURL waited behind suspended loader work")
    if result == .timedOut {
      XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
    }
    assertContextCount(0)
  }

  func testSignedURLRefreshKeepsCacheIdentityAndRestoresFreshURI() throws {
    let firstURI = "https://example.invalid/private.mp4?signature=old"
    let freshURI = "https://example.invalid/private.mp4?signature=fresh"
    let old = try XCTUnwrap(loader.prepareURL(
      for: firstURI, headers: ["Authorization": "Bearer private"], cacheKey: "stable"
    ))
    let fresh = try XCTUnwrap(loader.prepareURL(
      for: freshURI, headers: ["Authorization": "Bearer private"], cacheKey: "stable"
    ))
    XCTAssertEqual(CachingResourceLoader.identity(from: old), CachingResourceLoader.identity(from: fresh))
    XCTAssertEqual(CachingResourceLoader.originalURL(from: old)?.absoluteString, firstURI)
    XCTAssertEqual(CachingResourceLoader.originalURL(from: fresh)?.absoluteString, freshURI)
    loader.releaseURL(old)
    assertContextCount(1)
    loader.releaseURL(fresh)
    assertContextCount(0)
  }

  func testFailedReplacementPreservesCompletedEntry() throws {
    let payload = Data(repeating: 0xA7, count: CachingResourceLoader.chunkSize + 73)
    let source = fixtureRoot.appendingPathComponent("incoming")
    try payload.write(to: source)
    let identity = MediaCacheIdentity.make(uri: "https://example.invalid/clip.mp4", headers: [:])
    cache.store(temporaryFile: source, identity: identity, contentType: "public.mpeg-4")
    cache.waitForPendingWorkForTesting()
    let original = try XCTUnwrap(cache.cachedFile(forIdentity: identity))
    XCTAssertEqual(try Data(contentsOf: original.url), payload)
    let missing = fixtureRoot.appendingPathComponent("missing-replacement")
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    cache.store(temporaryFile: missing, identity: identity, contentType: "invalid-replacement-type")
    cache.waitForPendingWorkForTesting()
    let retained = try XCTUnwrap(cache.cachedFile(forIdentity: identity))
    XCTAssertEqual(retained.byteCount, Int64(payload.count))
    XCTAssertEqual(retained.contentType, "public.mpeg-4")
    XCTAssertEqual(try Data(contentsOf: retained.url), payload)
  }

  func testCompletedBoundedRequestDrainsAllChunksBeforeEOF() {
    assertCompletedDrain(openEnded: false, startOffset: 0)
    assertCompletedDrain(openEnded: false, startOffset: 137)
  }

  func testCompletedOpenEndedRequestIgnoresRequestedLengthAndDrainsAllChunks() {
    assertCompletedDrain(openEnded: true, startOffset: 0)
    assertCompletedDrain(openEnded: true, startOffset: 137)
  }

  private func assertCompletedDrain(
    openEnded: Bool, startOffset: Int64, file: StaticString = #filePath, line: UInt = #line
  ) {
    let length = Int64(CachingResourceLoader.chunkSize * 4 + 73)
    let byteCount = startOffset + length
    let requestedLength: Int64 = openEnded ? 1 : length
    var offset = startOffset
    var responses = 0
    while offset < byteCount {
      let chunk = CachingResourceLoader.chunkPlan(
        requestedLength: requestedLength,
        alreadyServed: offset - startOffset,
        currentOffset: offset,
        byteCount: byteCount,
        requestsAllDataToEndOfResource: openEnded
      )
      XCTAssertGreaterThan(chunk, 0, file: file, line: line)
      guard chunk > 0 else { return }
      XCTAssertLessThanOrEqual(chunk, Int64(CachingResourceLoader.chunkSize), file: file, line: line)
      offset += chunk
      responses += 1
    }
    XCTAssertEqual(responses, 5, file: file, line: line)
    XCTAssertEqual(offset - startOffset, length, file: file, line: line)
  }
}

final class SourceRequestPolicyTests: XCTestCase {
  private let credentials = ["Authorization": "Bearer secret", "X-Api-Key": "key-123", "Range": "bytes=0-"]

  func testHeadersStayOnSourceOriginAndExplicitHttpsOrigins() {
    let policy = SourceRequestPolicy(
      sourceURI: "https://media.test/master.m3u8", headers: credentials,
      trustedOrigins: ["HTTPS://CDN.test:443/", "http://plain.test", "https://[::1]:8443"]
    )
    for allowed in ["https://media.test/seg.ts", "https://MEDIA.test:443/key", "https://cdn.test/a", "https://[::1]:8443/x"] {
      XCTAssertTrue(policy.allowsHeaders(for: URL(string: allowed)!), allowed)
    }
    for denied in [
      "http://media.test/seg.ts", "https://media.test:8443/seg.ts", "https://evil.media.test/a",
      "https://media.test.evil/a", "https://cdn.test:8443/a", "http://cdn.test/a", "http://plain.test/a",
      "https://[::1]/x", "file:///tmp/a.mp4",
    ] {
      XCTAssertFalse(policy.allowsHeaders(for: URL(string: denied)!), denied)
    }
    XCTAssertNil(policy.headers["range"], "Range stays under loader control")
  }

  func testApplyStripsEveryCredentialOnUntrustedRedirectTargets() {
    let policy = SourceRequestPolicy(sourceURI: "https://media.test/v.mp4", headers: credentials, trustedOrigins: [])
    var redirected = URLRequest(url: URL(string: "https://other.test/v.mp4")!)
    redirected.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    redirected.setValue("key-123", forHTTPHeaderField: "x-api-key")
    redirected.setValue("bytes=10-20", forHTTPHeaderField: "Range")
    policy.apply(to: &redirected)
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(redirected.value(forHTTPHeaderField: "X-Api-Key"))
    XCTAssertEqual(redirected.value(forHTTPHeaderField: "Range"), "bytes=10-20")

    var back = URLRequest(url: URL(string: "https://media.test/v.mp4")!)
    policy.apply(to: &back)
    XCTAssertEqual(back.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    XCTAssertEqual(back.value(forHTTPHeaderField: "X-Api-Key"), "key-123")
  }

  func testTrustedOriginsPartitionAuthenticatedIdentitiesOnly() {
    let uri = "https://media.test/v.mp4"
    let auth = ["Authorization": "Bearer t"]
    XCTAssertNotEqual(
      MediaCacheIdentity.make(uri: uri, headers: auth),
      MediaCacheIdentity.make(uri: uri, headers: auth, trustedOrigins: ["https://cdn.test"])
    )
    XCTAssertEqual(
      MediaCacheIdentity.make(uri: uri, headers: auth, trustedOrigins: ["https://cdn.test", "https://b.test"]),
      MediaCacheIdentity.make(uri: uri, headers: auth, trustedOrigins: ["https://B.test:443/", "https://CDN.test"])
    )
    XCTAssertEqual(
      MediaCacheIdentity.make(uri: uri, headers: [:]),
      MediaCacheIdentity.make(uri: uri, headers: [:], trustedOrigins: ["https://cdn.test"])
    )
    let source = RegisteredSource(id: "a", uri: uri, rank: 0, kind: .progressive, headers: auth)
    var trusted = source
    trusted.trustedHeaderOrigins = ["https://cdn.test"]
    XCTAssertNotEqual(source.playbackIdentity, trusted.playbackIdentity)
    XCTAssertNotEqual(source.resourceIdentity, trusted.resourceIdentity)
  }
}

final class StreamingPrimitivesTests: XCTestCase {
  func testByteRangeSetMergesAndFindsGaps() {
    var set = ByteRangeSet()
    set.insert(10..<20)
    set.insert(0..<5)
    XCTAssertEqual(set.firstGap(below: 30), 5)
    set.insert(5..<10)
    XCTAssertEqual(set.ranges, [0..<20])
    XCTAssertEqual(set.end(containing: 7), 20)
    XCTAssertNil(set.end(containing: 20))
    XCTAssertFalse(set.covers(30))
    set.insert(15..<30)
    XCTAssertTrue(set.covers(30))
    XCTAssertNil(set.firstGap(below: 30))
  }

  func testRangeBufferDeduplicatesOverlapsAndReadsExactOffsets() {
    var buffer = MediaRangeBuffer()
    let bytes = Data((0..<100).map { UInt8($0) })
    XCTAssertEqual(buffer.insert(bytes.subdata(in: 10..<40), at: 10), 30)
    XCTAssertEqual(buffer.insert(bytes.subdata(in: 0..<60), at: 0), 30, "only uncovered bytes are added")
    XCTAssertEqual(buffer.byteCount, 60)
    XCTAssertEqual(buffer.read(at: 25, maxLength: 4), bytes.subdata(in: 25..<29))
    XCTAssertEqual(buffer.contiguousEnd(from: 0), 60)
    XCTAssertNil(buffer.read(at: 60, maxLength: 1))
    let sliced = bytes[50..<100]
    buffer.insert(Data(sliced), at: 50)
    XCTAssertEqual(buffer.read(at: 99, maxLength: 10), Data([99]))
  }

  func testRangeBufferTrimKeepsChunksNearWaitingOffsets() {
    var buffer = MediaRangeBuffer()
    for offset in stride(from: Int64(0), to: 100, by: 10) {
      buffer.insert(Data(repeating: 1, count: 10), at: offset)
    }
    let released = buffer.trim(toFit: 30, keeping: [55])
    XCTAssertEqual(released, 70)
    XCTAssertEqual(buffer.byteCount, 30)
    XCTAssertNotNil(buffer.read(at: 55, maxLength: 1))
    XCTAssertEqual(buffer.removeAll(), 30)
  }

  func testTransferBudgetBoundsMemoryAndWakesWaitersInOrder() {
    let budget = MediaTransferBudget(limits: .init(totalBufferBytes: 100, maxActiveTransfers: 1))
    XCTAssertTrue(budget.reserveMemory(60))
    XCTAssertFalse(budget.reserveMemory(41))
    budget.releaseMemory(60)
    XCTAssertEqual(budget.peakRetainedBytes, 60)
    XCTAssertTrue(budget.acquireTransfer())
    XCTAssertFalse(budget.acquireTransfer())
    var woken: [Int] = []
    let first = UUID()
    budget.enqueueWaiter(id: first, queue: .main) { woken.append(1) }
    budget.enqueueWaiter(id: UUID(), queue: .main) { woken.append(2) }
    budget.enqueueWaiter(id: first, queue: .main) { woken.append(9) }
    budget.releaseTransfer()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(woken, [1])
    XCTAssertEqual(budget.activeTransfers, 0)
  }
}

final class MediaDiskCacheClientTests: XCTestCase {
  private var root: URL!
  private var cache: MediaDiskCache!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("nfp-clients-\(UUID().uuidString)")
    cache = MediaDiskCache(rootURL: root)
  }

  override func tearDownWithError() throws {
    cache.waitForPendingWorkForTesting()
    try? FileManager.default.removeItem(at: root)
  }

  private func storage() -> (Int64, Int64, Int64) {
    let done = expectation(description: "storage")
    var result: (Int64, Int64, Int64) = (-1, -1, -1)
    cache.storageForTesting { result = ($0, $1, $2); done.fulfill() }
    wait(for: [done], timeout: 2)
    return result
  }

  private func stage(_ client: MediaDiskCache.Client, identity: String, bytes: Int) throws -> MediaDiskCache.PinnedFile? {
    let reservation = try XCTUnwrap(cache.reserve(bytes: Int64(bytes), identity: identity, client: client))
    try Data(repeating: 0x5A, count: bytes).write(to: reservation.url)
    let adopted = expectation(description: "adopted")
    var pin: MediaDiskCache.PinnedFile?
    cache.adopt(reservation, contentType: "public.mpeg-4") { pin = $0; adopted.fulfill() }
    wait(for: [adopted], timeout: 2)
    return pin
  }

  func testDisabledClientNeverReadsOrWritesWhileAnotherEngineCaches() throws {
    for disabledFirst in [true, false] {
      let disabled: MediaDiskCache.Client
      let enabled: MediaDiskCache.Client
      if disabledFirst {
        disabled = cache.register(enabled: false, maxBytes: 1 << 20)
        enabled = cache.register(enabled: true, maxBytes: 1 << 20)
      } else {
        enabled = cache.register(enabled: true, maxBytes: 1 << 20)
        disabled = cache.register(enabled: false, maxBytes: 1 << 20)
      }
      let identity = UUID().uuidString.replacingOccurrences(of: "-", with: "")
      XCTAssertNil(cache.reserve(bytes: 10, identity: identity, client: disabled))
      let pin = try XCTUnwrap(try stage(enabled, identity: identity, bytes: 10))
      cache.unpin(pin)
      XCTAssertNil(cache.pinnedFile(forIdentity: identity, client: disabled))
      XCTAssertNil(cache.cachedFile(forIdentity: identity, client: disabled))
      XCTAssertNotNil(cache.cachedFile(forIdentity: identity, client: enabled))
      cache.release(disabled)
      XCTAssertNotNil(cache.cachedFile(forIdentity: identity, client: enabled), "disabling one engine keeps the other's cache")
      cache.release(enabled)
      XCTAssertNil(cache.cachedFile(forIdentity: identity, client: enabled))
    }
  }

  func testFirstEnabledLeaseSetsBudgetUntilAllEnabledLeasesEnd() throws {
    let large = cache.register(enabled: true, maxBytes: 1000)
    let small = cache.register(enabled: true, maxBytes: 100)
    XCTAssertNotNil(try stage(large, identity: "a", bytes: 400).map { cache.unpin($0) })
    XCTAssertNil(cache.reserve(bytes: 400, identity: "b", client: small), "a client's own maximum still applies")
    cache.release(large)
    XCTAssertNotNil(cache.cachedFile(forIdentity: "a", client: small), "budget unchanged while a lease remains")
    cache.release(small)
    let fresh = cache.register(enabled: true, maxBytes: 100)
    cache.waitForPendingWorkForTesting()
    XCTAssertNil(cache.cachedFile(forIdentity: "a", client: fresh), "the new budget applies once every lease ended")
    cache.release(fresh)
  }

  func testReservationsCountAgainstTheBudgetAndAreReleasedExactlyOnce() throws {
    let client = cache.register(enabled: true, maxBytes: 100)
    let first = try XCTUnwrap(cache.reserve(bytes: 60, identity: "a", client: client))
    XCTAssertNil(cache.reserve(bytes: 60, identity: "b", client: client))
    XCTAssertEqual(storage().1, 60)
    cache.cancel(first)
    cache.cancel(first)
    XCTAssertEqual(storage().1, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
    let second = try XCTUnwrap(cache.reserve(bytes: 60, identity: "b", client: client))
    cache.release(client)
    XCTAssertEqual(storage().1, 0, "releasing a lease discards its staging")
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
  }

  func testEvictionDuringTransferPreventsLateAdoption() throws {
    let client = cache.register(enabled: true, maxBytes: 1000)
    for evictAll in [true, false] {
      let reservation = try XCTUnwrap(cache.reserve(bytes: 10, identity: "late", client: client))
      try Data(repeating: 1, count: 10).write(to: reservation.url)
      let evicted = expectation(description: "evicted")
      if evictAll {
        cache.evictAll { evicted.fulfill() }
      } else {
        cache.evict(identities: ["late"]) { evicted.fulfill() }
      }
      wait(for: [evicted], timeout: 2)
      let adopted = expectation(description: "adoption attempted")
      cache.adopt(reservation, contentType: nil) { XCTAssertNil($0); adopted.fulfill() }
      wait(for: [adopted], timeout: 2)
      XCTAssertNil(cache.cachedFile(forIdentity: "late", client: client))
    }
    XCTAssertEqual(storage().1, 0)
    cache.release(client)
  }

  func testEvictedPinnedFileStaysReadableAndBudgetedUntilUnpinned() throws {
    let client = cache.register(enabled: true, maxBytes: 1000)
    let adoptedPin = try XCTUnwrap(try stage(client, identity: "pinned", bytes: 300))
    let (readerPin, handle) = try XCTUnwrap(cache.pinnedFile(forIdentity: "pinned", client: client))
    let evicted = expectation(description: "evicted")
    cache.evictAll { evicted.fulfill() }
    wait(for: [evicted], timeout: 2)
    XCTAssertEqual(storage().0, 0)
    XCTAssertEqual(storage().2, 300, "a retired pinned file still counts")
    XCTAssertEqual(try handle.readCompat(upToCount: 300)?.count, 300)
    XCTAssertNil(cache.reserve(bytes: 800, identity: "x", client: client))
    cache.unpin(adoptedPin)
    XCTAssertEqual(storage().2, 300)
    cache.unpin(readerPin)
    XCTAssertEqual(storage().2, 0)
    try handle.close()
    XCTAssertNotNil(cache.reserve(bytes: 800, identity: "x", client: client))
    cache.release(client)
  }

  func testOrphanedStagingFromAPreviousProcessIsRemovedOnFirstLease() throws {
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 10).write(to: staging.appendingPathComponent("orphan"))
    let client = cache.register(enabled: true, maxBytes: 1000)
    cache.waitForPendingWorkForTesting()
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("orphan").path))
    cache.release(client)
  }
}

/// Serves the bundled clip with configurable HTTP behaviour and records every
/// request the loader makes.
private final class MediaStubProtocol: URLProtocol {
  struct Behavior {
    var payload = Data()
    var honorsRange = true
    var declaresLength = true
    var etags: [String]?
    var contentRangeShift: Int64 = 0
  }

  private static let lock = NSLock()
  private static var behavior = Behavior()
  private static var recorded: [URLRequest] = []

  static func reset(_ behavior: Behavior) {
    lock.withLock {
      self.behavior = behavior
      recorded = []
    }
  }

  static var requests: [URLRequest] { lock.withLock { recorded } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let (behavior, index): (Behavior, Int) = Self.lock.withLock {
      Self.recorded.append(request)
      return (Self.behavior, Self.recorded.count - 1)
    }
    let total = Int64(behavior.payload.count)
    var start: Int64 = 0
    var end = total - 1
    var status = 200
    var headers = ["Content-Type": "video/mp4", "Accept-Ranges": behavior.honorsRange ? "bytes" : "none"]
    if behavior.honorsRange, let range = request.value(forHTTPHeaderField: "Range"),
      range.hasPrefix("bytes=")
    {
      let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
      start = Int64(bounds[0]) ?? 0
      end = bounds.count > 1 && !bounds[1].isEmpty ? min(Int64(bounds[1]) ?? end, total - 1) : total - 1
      status = 206
      if start >= total {
        headers["Content-Range"] = "bytes */\(total)"
        let response = HTTPURLResponse(url: request.url!, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
        return
      }
      headers["Content-Range"] =
        "bytes \(start + behavior.contentRangeShift)-\(end + behavior.contentRangeShift)/\(total)"
    }
    if let etags = behavior.etags {
      headers["ETag"] = etags[min(index, etags.count - 1)]
    }
    if behavior.declaresLength {
      headers["Content-Length"] = "\(end - start + 1)"
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    var cursor = Int(start)
    while cursor <= Int(end) {
      let next = min(Int(end) + 1, cursor + 1024)
      client?.urlProtocol(self, didLoad: behavior.payload.subdata(in: cursor..<next))
      cursor = next
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Drives real AVFoundation playback through the streaming loader with tight
/// injected limits, so the bundled clip exceeds every memory window.
final class StreamingLoaderTests: XCTestCase {
  private var root: URL!
  private var cache: MediaDiskCache!
  private var budget: MediaTransferBudget!
  private var loader: CachingResourceLoader!
  private var failures: [NSError] = []
  private var fixture = Data()
  private let uri = "https://media.test/clip.mp4"
  private let headers = ["Authorization": "Bearer secret"]

  override func setUpWithError() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_clip.mp4")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "local video fixture unavailable")
    fixture = try Data(contentsOf: url)
    root = FileManager.default.temporaryDirectory.appendingPathComponent("nfp-stream-\(UUID().uuidString)")
    cache = MediaDiskCache(rootURL: root)
    makeLoader(limits: .init(chunkSize: 1024, fetchSize: 2048, perResourceBytes: 4096, totalBufferBytes: 8192, maxActiveTransfers: 2))
  }

  override func tearDownWithError() throws {
    loader?.shutdown()
    cache?.waitForPendingWorkForTesting()
    if let root {
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func makeLoader(limits: MediaTransferBudget.Limits) {
    loader?.shutdown()
    budget = MediaTransferBudget(limits: limits)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MediaStubProtocol.self]
    loader = CachingResourceLoader(
      sessionConfiguration: configuration,
      queue: DispatchQueue(label: "streaming-tests.\(UUID().uuidString)"),
      cache: cache, budget: budget
    )
    failures = []
    loader.onFailure = { [weak self] _, error in
      DispatchQueue.main.async { self?.failures.append(error as NSError) }
    }
  }

  private struct Outcome {
    var ready = false
    var advanced = false
  }

  /// Loads and plays the asset; returns once it advanced, failed, or timed out.
  private func play(client: MediaDiskCache.Client?, seekBack: Bool = false, timeout: TimeInterval = 10) -> Outcome {
    var outcome = Outcome()
    autoreleasepool {
      guard let asset = loader.prepareAsset(for: uri, headers: headers, client: client) else { return }
      let item = AVPlayerItem(asset: asset)
      let player = AVPlayer(playerItem: item)
      player.automaticallyWaitsToMinimizeStalling = false
      player.isMuted = true
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline, item.status == .unknown {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      }
      guard item.status == .readyToPlay else { return }
      outcome.ready = true
      player.play()
      while Date() < deadline, player.currentTime().seconds < 0.3, item.status != .failed {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      }
      outcome.advanced = player.currentTime().seconds >= 0.3
      if seekBack, outcome.advanced {
        let sought = expectation(description: "backward seek")
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in sought.fulfill() }
        wait(for: [sought], timeout: timeout)
        let resumeDeadline = Date().addingTimeInterval(timeout)
        while Date() < resumeDeadline, player.currentTime().seconds < 0.2, item.status != .failed {
          RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        outcome.advanced = player.currentTime().seconds >= 0.2
      }
      // Give low-priority cache fills a moment while the asset is alive.
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      player.pause()
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    return outcome
  }

  private func waitForFailure(timeout: TimeInterval = 10) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, failures.isEmpty {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  private var identity: String { MediaCacheIdentity.make(uri: uri, headers: headers) }

  private func storage() -> (entries: Int64, reserved: Int64, retired: Int64) {
    let done = expectation(description: "storage")
    var result: (Int64, Int64, Int64) = (-1, -1, -1)
    cache.storageForTesting { result = ($0, $1, $2); done.fulfill() }
    wait(for: [done], timeout: 2)
    return result
  }

  private func stagingFiles() -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("staging"), includingPropertiesForKeys: nil
    )) ?? []
  }

  private func assertBoundedRangeRequests(file: StaticString = #filePath, line: UInt = #line) {
    let requests = MediaStubProtocol.requests
    XCTAssertFalse(requests.isEmpty, file: file, line: line)
    XCTAssertGreaterThan(requests.count, 1, "the clip spans several bounded ranges", file: file, line: line)
    for request in requests {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret", file: file, line: line)
      guard let range = request.value(forHTTPHeaderField: "Range"),
        let bounds = Optional(range.dropFirst(6).split(separator: "-")), bounds.count == 2,
        let start = Int64(bounds[0]), let end = Int64(bounds[1])
      else {
        return XCTFail("unbounded request \(request)", file: file, line: line)
      }
      XCTAssertLessThanOrEqual(end - start + 1, Int64(budget.limits.fetchSize), file: file, line: line)
    }
    XCTAssertLessThanOrEqual(budget.peakRetainedBytes, budget.limits.totalBufferBytes, file: file, line: line)
  }

  func testMediaLargerThanCacheBudgetStreamsAndSeeksWithoutStaging() {
    MediaStubProtocol.reset(.init(payload: fixture))
    let client = cache.register(enabled: true, maxBytes: 1024)
    let outcome = play(client: client, seekBack: true)
    XCTAssertTrue(outcome.ready)
    XCTAssertTrue(outcome.advanced, "playback and a backward seek continue past the cache budget")
    XCTAssertTrue(failures.isEmpty, "\(failures)")
    assertBoundedRangeRequests()
    XCTAssertEqual(storage().entries, 0)
    XCTAssertEqual(storage().reserved, 0)
    XCTAssertTrue(stagingFiles().isEmpty)
    cache.release(client)
  }

  func testSmallMediaIsStagedAtValidatedOffsetsAndAdopted() throws {
    MediaStubProtocol.reset(.init(payload: fixture))
    let client = cache.register(enabled: true, maxBytes: 1 << 20)
    let outcome = play(client: client)
    XCTAssertTrue(outcome.ready && outcome.advanced)
    assertBoundedRangeRequests()
    let cached = try XCTUnwrap(cache.cachedFile(forIdentity: identity, client: client))
    XCTAssertEqual(try Data(contentsOf: cached.url), fixture)
    XCTAssertEqual(storage().reserved, 0)

    MediaStubProtocol.reset(.init(payload: fixture))
    XCTAssertTrue(play(client: client).advanced)
    XCTAssertTrue(MediaStubProtocol.requests.isEmpty, "a cached clip replays without the network")
    cache.release(client)
  }

  func testDisabledEngineWritesNothingWhileAnotherEngineCaches() {
    MediaStubProtocol.reset(.init(payload: fixture))
    let enabled = cache.register(enabled: true, maxBytes: 1 << 20)
    let disabled = cache.register(enabled: false, maxBytes: 1 << 20)
    XCTAssertTrue(play(client: disabled).advanced)
    XCTAssertEqual(storage().entries, 0)
    XCTAssertTrue(stagingFiles().isEmpty)
    XCTAssertTrue(play(client: enabled).advanced)
    XCTAssertGreaterThan(storage().entries, 0)
    MediaStubProtocol.reset(.init(payload: fixture))
    XCTAssertTrue(play(client: disabled).advanced)
    XCTAssertFalse(MediaStubProtocol.requests.isEmpty, "a disabled engine never reads the shared cache")
    cache.release(disabled)
    cache.release(enabled)
  }

  func testServerIgnoringRangesFallsBackToBoundedSequentialStreaming() {
    MediaStubProtocol.reset(.init(payload: fixture, honorsRange: false))
    let outcome = play(client: nil, seekBack: true)
    XCTAssertTrue(outcome.ready && outcome.advanced)
    XCTAssertTrue(failures.isEmpty, "\(failures)")
    XCTAssertLessThanOrEqual(budget.peakRetainedBytes, budget.limits.totalBufferBytes)
  }

  func testUnknownLengthIsSpooledOnlyWithinTheBuffer() {
    MediaStubProtocol.reset(.init(payload: fixture, honorsRange: false, declaresLength: false))
    XCTAssertFalse(play(client: nil, timeout: 5).ready)
    waitForFailure()
    XCTAssertEqual(failures.first?.domain, CachingResourceLoader.errorDomain)
    XCTAssertEqual(failures.first?.code, CachingResourceLoader.ErrorCode.unsupportedResponse.rawValue)
    XCTAssertLessThanOrEqual(budget.peakRetainedBytes, budget.limits.perResourceBytes)

    makeLoader(limits: .init(chunkSize: 1024, fetchSize: 2048, perResourceBytes: 64 * 1024, totalBufferBytes: 128 * 1024))
    MediaStubProtocol.reset(.init(payload: fixture, honorsRange: false, declaresLength: false))
    XCTAssertTrue(play(client: nil).advanced, "short unknown-length media still plays")
  }

  func testMalformedContentRangeIsATypedProtocolError() {
    MediaStubProtocol.reset(.init(payload: fixture, contentRangeShift: 1))
    XCTAssertFalse(play(client: nil, timeout: 5).ready)
    waitForFailure()
    XCTAssertEqual(failures.first?.code, CachingResourceLoader.ErrorCode.protocolViolation.rawValue)
  }

  func testRepresentationChangeMidStreamIsDetected() {
    MediaStubProtocol.reset(.init(payload: fixture, etags: ["\"a\"", "\"b\""]))
    _ = play(client: nil, timeout: 5)
    waitForFailure()
    XCTAssertEqual(failures.first?.code, CachingResourceLoader.ErrorCode.representationChanged.rawValue)
    XCTAssertTrue(MediaStubProtocol.requests.contains {
      $0.value(forHTTPHeaderField: "If-Range") == "\"a\""
    }, "later ranges are conditional on the first representation")
  }

  func testReleasingTheAssetEndsItsTransferAndUnfinishedStaging() {
    MediaStubProtocol.reset(.init(payload: fixture))
    let client = cache.register(enabled: true, maxBytes: 1 << 20)
    autoreleasepool {
      let asset = loader.prepareAsset(for: uri, headers: headers, client: client)
      asset?.loadValuesAsynchronously(forKeys: ["duration"]) {}
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let counted = expectation(description: "transfers")
    loader.transferCountForTesting { XCTAssertEqual($0, 0); counted.fulfill() }
    wait(for: [counted], timeout: 2)
    XCTAssertEqual(storage().reserved, 0)
    XCTAssertEqual(budget.activeTransfers, 0)
    XCTAssertEqual(budget.retainedBytes, 0)
    cache.release(client)
  }
}

private final class ReplacementTestPlayer: AVQueuePlayer {
  let readyItem = RecoveryReadyItem(url: URL(fileURLWithPath: "/dev/null"))
  private var selectedItem: AVPlayerItem?
  private var playbackStatus: AVPlayer.TimeControlStatus = .paused
  override var currentItem: AVPlayerItem? { selectedItem }
  override var timeControlStatus: AVPlayer.TimeControlStatus { playbackStatus }
  override func insert(_ item: AVPlayerItem, after afterItem: AVPlayerItem?) { select(readyItem) }
  override func removeAllItems() { select(nil) }
  override func play() { transition(to: .playing) }
  override func playImmediately(atRate rate: Float) { transition(to: .playing) }
  override func pause() { transition(to: .paused) }

  func select(_ item: AVPlayerItem?) {
    willChangeValue(forKey: "currentItem")
    selectedItem = item
    didChangeValue(forKey: "currentItem")
  }

  func transition(to status: AVPlayer.TimeControlStatus) {
    guard playbackStatus != status else { return }
    willChangeValue(forKey: "timeControlStatus")
    playbackStatus = status
    didChangeValue(forKey: "timeControlStatus")
  }
}

private final class RecoveryReadyItem: AVPlayerItem {
  override var status: AVPlayerItem.Status { .readyToPlay }
}

final class LoopStateAndAudioSessionTests: XCTestCase {
  private func config(muted: Bool, handleAudioFocus: Bool = false, manageAudioSession: Bool = true) -> FeedPlayerConfigMessage {
    FeedPlayerConfigMessage(
      maxActivePlayers: 3, preloadAhead: 0, preloadBehind: 0, maxConcurrentPreloads: 1,
      positionUpdateIntervalMs: 200, renderMode: .platformView,
      cache: CachePolicyMessage(enabled: false, maxBytes: 1024),
      audio: AudioPolicyMessage(
        muted: muted, volume: 1, handleAudioFocus: handleAudioFocus, manageAudioSession: manageAudioSession
      )
    )
  }

  func testReplacementItemDuringPlaybackKeepsPlayingStateButStallsStillBuffer() throws {
    let player = ReplacementTestPlayer()
    var states: [PlaybackStatusMessage] = []
    let manager = AVPlayerManager(
      onState: { _, state, _ in states.append(state) }, onReleased: { _, _ in }, onPosition: { _ in },
      onMetrics: { _ in }, onVideoSize: { _ in }, makePlayer: { player }, applicationState: { .active },
      setAudioSessionActive: { _, _ in }
    )
    manager.initialize(config: config(muted: true, manageAudioSession: false))
    defer { manager.disposeAll() }
    try manager.setSources([RegisteredSource(id: "clip", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:])])
    try manager.createController(controllerId: 90, sourceId: "clip", autoPlay: false, looping: false)
    XCTAssertTrue(states.contains(.ready))
    manager.play(controllerId: 90)
    XCTAssertEqual(states.last, .playing)

    let mark = states.count
    for _ in 0..<3 {
      player.select(AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")))
      player.select(player.readyItem)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertFalse(states[mark...].contains(.preparing), "loop replicas must not report preparing: \(states)")

    player.transition(to: .waitingToPlayAtSpecifiedRate)
    XCTAssertEqual(states.last, .buffering)
    player.transition(to: .playing)
    XCTAssertEqual(states.last, .playing)
  }

  private func manager() -> AVPlayerManager {
    AVPlayerManager(
      onState: { _, _, _ in }, onReleased: { _, _ in }, onPosition: { _ in }, onMetrics: { _ in },
      onVideoSize: { _ in }, setAudioSessionActive: { _, _ in }
    )
  }

  private func addSources(_ manager: AVPlayerManager) throws {
    try manager.setSources([
      RegisteredSource(id: "a", uri: "file:///dev/null", rank: 0, kind: .auto, headers: [:]),
      RegisteredSource(id: "b", uri: "file:///dev/null?b", rank: 1, kind: .auto, headers: [:]),
    ])
  }

  func testIndividualUnmuteUnderMutedPolicyLeavesTheAmbientCategory() throws {
    let session = AVAudioSession.sharedInstance()
    defer { try? session.setCategory(.playback, mode: .moviePlayback, options: []) }
    for handleFocus in [false, true] {
      let manager = manager()
      manager.initialize(config: config(muted: true, handleAudioFocus: handleFocus))
      try addSources(manager)
      try manager.createController(controllerId: 1, sourceId: "a", autoPlay: false, looping: false)
      XCTAssertEqual(session.category, .ambient)
      manager.setMuted(controllerId: 1, value: false)
      XCTAssertEqual(session.category, .playback)
      XCTAssertEqual(session.mode, .moviePlayback)
      XCTAssertEqual(session.categoryOptions.contains(.mixWithOthers), !handleFocus, "focus policy is preserved")
      manager.setVolume(controllerId: 1, value: 0)
      XCTAssertEqual(session.category, .ambient, "a silent controller is not audible output")
      manager.setVolume(controllerId: 1, value: 0.5)
      XCTAssertEqual(session.category, .playback)
      manager.setMuted(controllerId: 1, value: true)
      XCTAssertEqual(session.category, .ambient)
      manager.disposeAll()
    }
  }

  func testMutingOneControllerKeepsAnotherAudibleAndReleaseRecomputes() throws {
    let session = AVAudioSession.sharedInstance()
    defer { try? session.setCategory(.playback, mode: .moviePlayback, options: []) }
    let manager = manager()
    manager.initialize(config: config(muted: false))
    defer { manager.disposeAll() }
    try addSources(manager)
    try manager.createController(controllerId: 1, sourceId: "a", autoPlay: false, looping: false)
    try manager.createController(controllerId: 2, sourceId: "b", autoPlay: false, looping: false)
    manager.setMuted(controllerId: 2, value: true)
    XCTAssertEqual(session.category, .playback)
    manager.disposeController(controllerId: 1)
    XCTAssertEqual(session.category, .ambient, "only a muted controller remains")
    manager.applyAudioPolicy(AudioPolicyMessage(muted: false, volume: 1, handleAudioFocus: false, manageAudioSession: true))
    XCTAssertEqual(session.category, .playback)
  }

  func testHostOwnedSessionIsNeverReconfiguredByControllerChanges() throws {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: [.duckOthers])
    defer { try? session.setCategory(.playback, mode: .moviePlayback, options: []) }
    let manager = manager()
    manager.initialize(config: config(muted: true, manageAudioSession: false))
    defer { manager.disposeAll() }
    try addSources(manager)
    try manager.createController(controllerId: 1, sourceId: "a", autoPlay: false, looping: false)
    manager.setMuted(controllerId: 1, value: false)
    manager.setMuted(controllerId: 1, value: true)
    XCTAssertEqual(session.category, .playback)
    XCTAssertTrue(session.categoryOptions.contains(.duckOthers))
  }
}
