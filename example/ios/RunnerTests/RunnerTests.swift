import XCTest

@testable import native_feed_player

/// Swift-side unit tests for the plugin's scheduling and cache logic.
///
/// These mirror the Kotlin FeedSourceRegistryTest cases so both platforms are
/// held to the same windowing contract.
final class FeedSourceRegistryTests: XCTestCase {
  private func source(_ id: String, rank: Int, uri: String? = nil) -> RegisteredSource {
    RegisteredSource(
      id: id,
      uri: uri ?? "https://example.test/\(id).mp4",
      rank: rank,
      kind: .auto,
      headers: [:]
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

    // Appending must not disturb the viewport or renumber earlier sources.
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

    // Travelling backwards, so the larger budget lands on lower ranks.
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

    // The nearer occurrence wins; the clip is not prepared twice.
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
}

final class CachingResourceLoaderTests: XCTestCase {
  func testInterceptedUrlRoundTrips() {
    let original = "https://example.test/clip.mp4?token=abc"

    guard let intercepted = CachingResourceLoader.interceptURL(for: original) else {
      return XCTFail("expected an intercepted URL")
    }

    // AVFoundation only delegates schemes it does not understand, so the real
    // scheme has to be hidden and then restored.
    XCTAssertEqual(intercepted.scheme, "nfpcache-https")
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
  func testInitializeReplacesPreviousSession() throws {
    var released: [(Int, ReleaseReasonMessage)] = []
    let manager = AVPlayerManager(
      onState: { _, _, _ in },
      onReleased: { released.append(($0, $1)) },
      onPosition: { _ in },
      onMetrics: { _ in },
      onVideoSize: { _ in }
    )
    let config = FeedPlayerConfigMessage(
      maxActivePlayers: 3,
      preloadAhead: 2,
      preloadBehind: 1,
      maxConcurrentPreloads: 2,
      positionUpdateIntervalMs: 200,
      renderMode: .platformView,
      cache: CachePolicyMessage(enabled: false, maxBytes: 0),
      audio: AudioPolicyMessage(muted: true, volume: 1, handleAudioFocus: false)
    )

    manager.initialize(config: config)
    manager.setSources([
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
}
