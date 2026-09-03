import AVFoundation
import XCTest

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
      identity: source.cacheIdentity,
      error: URLError(.cannotConnectToHost)
    )
    manager.handleResourceFailure(
      identity: source.cacheIdentity,
      error: URLError(.cannotConnectToHost)
    )

    XCTAssertEqual(states.last, .error, "terminal error was overwritten: \(states)")
    XCTAssertEqual(states.filter { $0 == .error }.count, 1)
  }

  private func makeManager(onReleased: @escaping (Int) -> Void = { _ in }) -> AVPlayerManager {
    AVPlayerManager(
      onState: { _, _, _ in },
      onReleased: { controllerId, _ in onReleased(controllerId) },
      onPosition: { _ in },
      onMetrics: { _ in },
      onVideoSize: { _ in }
    )
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
