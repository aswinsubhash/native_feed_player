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

  func testPartialContentIsRejectedUntilRangesCanBeStoredAtTheirDeclaredOffsets() {
    XCTAssertFalse(CachingResourceLoader.isCacheableResponse(206))
    XCTAssertTrue(CachingResourceLoader.isCacheableResponse(200))
    XCTAssertFalse(CachingResourceLoader.isCacheableResponse(404))
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
  override func tearDown() {
    MediaDiskCache.shared.evictAll {
      MediaDiskCache.shared.configure(enabled: false, maxBytes: 0)
    }
    // The next test's configure must not race this teardown on the cache queue.
    MediaDiskCache.shared.waitForPendingWorkForTesting()
    super.tearDown()
  }

  func testConfigureAppliesTheNewBudgetToTheLoadBarrier() throws {
    // Seed a 4 KB entry under a generous budget.
    MediaDiskCache.shared.configure(enabled: true, maxBytes: 64 * 1024 * 1024)
    MediaDiskCache.shared.waitForPendingWorkForTesting()
    let identity = MediaCacheIdentity.make(
      uri: "https://example.test/budget-\(UUID().uuidString).mp4",
      headers: [:]
    )
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("nfp-test-\(UUID().uuidString)")
    try Data(repeating: 0xAB, count: 4096).write(to: temporary)
    MediaDiskCache.shared.store(temporaryFile: temporary, identity: identity, contentType: "video/mp4")
    MediaDiskCache.shared.waitForPendingWorkForTesting()
    XCTAssertNotNil(MediaDiskCache.shared.cachedFile(forIdentity: identity))

    // Reconfigure with a 1 KB budget: the load barrier must enforce the NEW
    // budget, not the previous one, and evict the 4 KB entry.
    MediaDiskCache.shared.configure(enabled: true, maxBytes: 1024)
    XCTAssertTrue(MediaDiskCache.shared.isEnabled)
    MediaDiskCache.shared.waitForPendingWorkForTesting()
    XCTAssertNil(MediaDiskCache.shared.cachedFile(forIdentity: identity))
  }

  func testTruncatedCacheFileIsEvictedInsteadOfServed() throws {
    MediaDiskCache.shared.configure(enabled: true, maxBytes: 64 * 1024 * 1024)
    MediaDiskCache.shared.waitForPendingWorkForTesting()

    let identity = MediaCacheIdentity.make(
      uri: "https://example.test/truncated-\(UUID().uuidString).mp4",
      headers: [:]
    )
    let payload = Data(repeating: 0xAB, count: 4096)
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("nfp-test-\(UUID().uuidString)")
    try payload.write(to: temporary)
    MediaDiskCache.shared.store(temporaryFile: temporary, identity: identity, contentType: "video/mp4")
    MediaDiskCache.shared.waitForPendingWorkForTesting()

    XCTAssertNotNil(MediaDiskCache.shared.cachedFile(forIdentity: identity))

    // Simulate external truncation (crash mid-move, OS eviction).
    let url = MediaDiskCache.shared.fileURL(forKey: identity)
    try Data(repeating: 0xCD, count: 1024).write(to: url)

    XCTAssertNil(MediaDiskCache.shared.cachedFile(forIdentity: identity))
    MediaDiskCache.shared.waitForPendingWorkForTesting()
    XCTAssertNil(MediaDiskCache.shared.cachedFile(forIdentity: identity))
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

  private func makeCancellationDownload(finished: Bool) throws -> CachingResourceLoader.Download {
    let temporaryURL = fixtureRoot.appendingPathComponent("cancel-\(UUID().uuidString)")
    let payload = Data(repeating: 0xB3, count: CachingResourceLoader.chunkSize * 4 + 73)
    try payload.write(to: temporaryURL)
    let handle = try FileHandle(forWritingTo: temporaryURL)
    let identity = MediaCacheIdentity.make(uri: "https://example.invalid/cancel.mp4", headers: [:])
    let download = CachingResourceLoader.Download(
      identity: identity, requestIdentity: identity,
      temporaryURL: temporaryURL, handle: handle
    )
    download.receivedSuccessfulResponse = true
    download.bytesWritten = Int64(payload.count)
    download.contentLength = Int64(payload.count + (finished ? 0 : 100))
    download.contentType = "public.mpeg-4"
    download.finished = finished
    download.deliveryScheduled = true
    download.readHandle = try FileHandle(forReadingFrom: temporaryURL)
    if finished { try handle.close() }
    return download
  }

  func testNormalCancellationAdoptsCompletedDownload() throws {
    let download = try makeCancellationDownload(finished: true)
    var failures = 0
    loader.onFailure = { _, _ in failures += 1 }
    loaderQueue.sync {
      loader.cancelDownload(download, discardingCompleted: false)
      loader.cancelDownload(download, discardingCompleted: false)
    }
    cache.waitForPendingWorkForTesting()
    XCTAssertTrue(download.cleaned)
    XCTAssertNil(download.failure)
    XCTAssertNil(download.readHandle)
    XCTAssertEqual(failures, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: download.temporaryURL.path))
    let adopted = try XCTUnwrap(cache.cachedFile(forIdentity: download.identity))
    XCTAssertEqual(adopted.byteCount, download.bytesWritten)
    XCTAssertEqual(adopted.contentType, "public.mpeg-4")
    XCTAssertEqual(try Data(contentsOf: adopted.url),
      Data(repeating: 0xB3, count: CachingResourceLoader.chunkSize * 4 + 73))
  }

  func testExplicitCancellationDiscardsCompletedDownload() throws {
    let download = try makeCancellationDownload(finished: true)
    loaderQueue.sync {
      loader.cancelDownload(download, discardingCompleted: true)
      loader.cancelDownload(download, discardingCompleted: false)
    }
    cache.waitForPendingWorkForTesting()
    XCTAssertTrue(download.cleaned)
    XCTAssertNil(download.readHandle)
    XCTAssertEqual((download.failure as NSError?)?.domain, NSURLErrorDomain)
    XCTAssertEqual((download.failure as NSError?)?.code, NSURLErrorCancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: download.temporaryURL.path))
    XCTAssertNil(cache.cachedFile(forIdentity: download.identity))
  }

  func testNormalCancellationDiscardsIncompleteDownload() throws {
    let download = try makeCancellationDownload(finished: false)
    loaderQueue.sync { loader.cancelDownload(download, discardingCompleted: false) }
    cache.waitForPendingWorkForTesting()
    XCTAssertTrue(download.cleaned)
    XCTAssertTrue(download.finished)
    XCTAssertNil(download.readHandle)
    XCTAssertEqual((download.failure as NSError?)?.domain, NSURLErrorDomain)
    XCTAssertEqual((download.failure as NSError?)?.code, NSURLErrorCancelled)
    XCTAssertThrowsError(try download.handle.write(contentsOf: Data([0x01])))
    XCTAssertFalse(FileManager.default.fileExists(atPath: download.temporaryURL.path))
    XCTAssertNil(cache.cachedFile(forIdentity: download.identity))
  }

  func testNormalCancellationDoesNotAdoptFailedCompletedDownload() throws {
    let download = try makeCancellationDownload(finished: true)
    download.failure = URLError(.networkConnectionLost)
    var failures = 0
    loader.onFailure = { _, _ in failures += 1 }
    loaderQueue.sync { loader.cancelDownload(download, discardingCompleted: false) }
    cache.waitForPendingWorkForTesting()
    XCTAssertTrue(download.cleaned)
    XCTAssertNil(download.readHandle)
    XCTAssertEqual((download.failure as NSError?)?.code, NSURLErrorNetworkConnectionLost)
    XCTAssertEqual(failures, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: download.temporaryURL.path))
    XCTAssertNil(cache.cachedFile(forIdentity: download.identity))
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
      let decision = CachingResourceLoader.pendingDeliveryDecision(
        requestedLength: requestedLength,
        alreadyServed: offset - startOffset,
        currentOffset: offset,
        byteCount: byteCount,
        requestsAllDataToEndOfResource: openEnded,
        downloadFinished: true,
        contentInformationReady: true
      )
      XCTAssertEqual(decision, offset < byteCount ? .deliverMore : .complete, file: file, line: line)
    }
    XCTAssertEqual(responses, 5, file: file, line: line)
    XCTAssertEqual(offset - startOffset, length, file: file, line: line)
  }

  func testDeliveryDecisionDistinguishesWaitingFromTruePrematureEOF() {
    let chunk = Int64(CachingResourceLoader.chunkSize)
    XCTAssertEqual(CachingResourceLoader.pendingDeliveryDecision(
      requestedLength: chunk * 3, alreadyServed: chunk, currentOffset: chunk,
      byteCount: chunk * 2, requestsAllDataToEndOfResource: false,
      downloadFinished: true, contentInformationReady: true
    ), .deliverMore)
    XCTAssertEqual(CachingResourceLoader.pendingDeliveryDecision(
      requestedLength: chunk * 3, alreadyServed: chunk * 2, currentOffset: chunk * 2,
      byteCount: chunk * 2, requestsAllDataToEndOfResource: false,
      downloadFinished: true, contentInformationReady: true
    ), .unexpectedEOF)
    XCTAssertEqual(CachingResourceLoader.pendingDeliveryDecision(
      requestedLength: chunk * 3, alreadyServed: chunk * 2, currentOffset: chunk * 2,
      byteCount: chunk * 2, requestsAllDataToEndOfResource: false,
      downloadFinished: false, contentInformationReady: true
    ), .waitForData)
    XCTAssertEqual(CachingResourceLoader.pendingDeliveryDecision(
      requestedLength: chunk, alreadyServed: chunk, currentOffset: chunk,
      byteCount: chunk, requestsAllDataToEndOfResource: false,
      downloadFinished: false, contentInformationReady: false
    ), .waitForData)
    XCTAssertEqual(CachingResourceLoader.pendingDeliveryDecision(
      requestedLength: chunk, alreadyServed: chunk, currentOffset: chunk,
      byteCount: chunk, requestsAllDataToEndOfResource: false,
      downloadFinished: true, contentInformationReady: true
    ), .complete)
  }
}
