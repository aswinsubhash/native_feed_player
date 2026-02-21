import AVFoundation
import Foundation

/// AVPlayer lifecycle and event orchestration for native reels playback.
final class AVPlayerManager {
  typealias StateCallback = (_ controllerId: Int, _ state: String) -> Void
  typealias PositionCallback = (_ controllerId: Int, _ positionMs: Int64) -> Void
  typealias MetricsCallback = (_ controllerId: Int, _ metrics: [String: Any]) -> Void

  private struct PreloadedAsset {
    let url: String
    let asset: AVURLAsset
  }

  private struct PlaybackMetrics {
    let createdAtMs: Int64 = AVPlayerManager.currentUptimeMs()
    var firstFrameLatencyMs: Int64?
    var rebufferCount: Int = 0
    var droppedFramesEstimate: Int = 0
    var hasReady: Bool = false
  }

  private final class ManagedController {
    let id: Int
    let url: String
    let index: Int
    let player: AVPlayer
    let looping: Bool
    var itemStatusObservation: NSKeyValueObservation?
    var timeControlObservation: NSKeyValueObservation?
    var endObserver: NSObjectProtocol?

    init(id: Int, url: String, index: Int, player: AVPlayer, looping: Bool) {
      self.id = id
      self.url = url
      self.index = index
      self.player = player
      self.looping = looping
    }
  }

  private let onState: StateCallback
  private let onPosition: PositionCallback
  private let onMetrics: MetricsCallback

  private var controllers: [Int: ManagedController] = [:]
  private var creationOrder: [Int] = []
  private var sourcesByIndex: [Int: String] = [:]
  private var preloadedAssets: [Int: PreloadedAsset] = [:]
  private var metricsByController: [Int: PlaybackMetrics] = [:]
  private var pooledPlayers: [AVPlayer] = []
  private var attachedRenderViews: [Int: NativeVideoRenderView] = [:]
  private var maxCachedPlayers: Int = 5
  private var maxPooledPlayers: Int = 5
  private var preloadCount: Int = 2
  private var activeWindowRadius: Int = 2
  private var visibleIndex: Int = 0
  private var preloadGeneration: Int = 0
  private var positionTimer: Timer?

  init(
    onState: @escaping StateCallback,
    onPosition: @escaping PositionCallback,
    onMetrics: @escaping MetricsCallback
  ) {
    self.onState = onState
    self.onPosition = onPosition
    self.onMetrics = onMetrics
  }

  deinit {
    disposeAll()
  }

  func initialize(maxCachedPlayers: Int, preloadCount: Int) {
    self.maxCachedPlayers = max(1, maxCachedPlayers)
    self.maxPooledPlayers = max(1, self.maxCachedPlayers)
    self.preloadCount = max(0, preloadCount)
    self.activeWindowRadius = max(1, self.preloadCount)
    preloadGeneration += 1
    preloadedAssets.removeAll()
    drainPooledPlayers(keep: maxPooledPlayers)
    enforceVisibleWindowEviction()
    schedulePreloadWindow()
  }

  func preload(sources: [[String: Any]]) {
    sourcesByIndex.removeAll()
    for source in sources {
      guard let index = source["index"] as? Int else {
        continue
      }
      guard let url = source["url"] as? String, !url.isEmpty else {
        continue
      }
      sourcesByIndex[index] = url
    }

    if !sourcesByIndex.isEmpty, sourcesByIndex[visibleIndex] == nil {
      visibleIndex = sourcesByIndex.keys.min() ?? 0
    }

    enforceVisibleWindowEviction()
    schedulePreloadWindow()
  }

  func createController(
    controllerId: Int,
    url: String,
    index: Int,
    autoPlay: Bool,
    looping: Bool
  ) throws {
    guard let sourceURL = URL(string: url) else {
      throw NSError(
        domain: "native_reels_player",
        code: 1001,
        userInfo: [NSLocalizedDescriptionKey: "Invalid URL for createController: \(url)"]
      )
    }

    evictToPoolSizeIfNeeded()

    let item: AVPlayerItem
    if let preloaded = preloadedAssets[index], preloaded.url == url {
      item = AVPlayerItem(asset: preloaded.asset)
      preloadedAssets.removeValue(forKey: index)
    } else {
      preloadedAssets.removeValue(forKey: index)
      item = AVPlayerItem(url: sourceURL)
    }

    let player = obtainReusablePlayer()
    player.replaceCurrentItem(with: item)
    player.actionAtItemEnd = .pause
    player.automaticallyWaitsToMinimizeStalling = true
    let managed = ManagedController(
      id: controllerId,
      url: url,
      index: index,
      player: player,
      looping: looping
    )
    attachObservers(to: managed, playerItem: item)

    controllers[controllerId] = managed
    creationOrder.append(controllerId)
    metricsByController[controllerId] = PlaybackMetrics()
    emitMetrics(controllerId)
    attachedRenderViews[controllerId]?.setPlayer(player)
    onState(controllerId, "preparing")
    startPositionTimerIfNeeded()

    if autoPlay {
      player.play()
    }

    enforceVisibleWindowEviction()
    schedulePreloadWindow()
  }

  func play(controllerId: Int) {
    controllers[controllerId]?.player.play()
  }

  func pause(controllerId: Int) {
    controllers[controllerId]?.player.pause()
  }

  func seekTo(controllerId: Int, positionMs: Int64) {
    guard let player = controllers[controllerId]?.player else {
      return
    }
    let clampedMs = max(Int64(0), positionMs)
    let time = CMTime(value: clampedMs, timescale: 1000)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func disposeController(controllerId: Int) {
    disposeControllerInternal(controllerId: controllerId, emitDisposed: true, shouldReschedule: true)
  }

  func clearCache() {
    preloadGeneration += 1
    sourcesByIndex.removeAll()
    preloadedAssets.removeAll()
  }

  func setVisibleIndex(index: Int) {
    visibleIndex = index
    enforceVisibleWindowEviction()
    schedulePreloadWindow()
  }

  func attach(controllerId: Int, renderView: NativeVideoRenderView) {
    attachedRenderViews[controllerId] = renderView
    if let player = controllers[controllerId]?.player {
      renderView.setPlayer(player)
    } else {
      renderView.setPlayer(nil)
    }
  }

  func detach(controllerId: Int) {
    guard let renderView = attachedRenderViews.removeValue(forKey: controllerId) else {
      return
    }
    renderView.setPlayer(nil)
  }

  func onMemoryWarning() {
    preloadGeneration += 1
    preloadedAssets.removeAll()
    drainPooledPlayers(keep: 0)
    enforceVisibleWindowEviction(forceAggressive: true)
  }

  func disposeAll() {
    preloadGeneration += 1
    let ids = Array(controllers.keys)
    for controllerId in ids {
      disposeControllerInternal(controllerId: controllerId, emitDisposed: true, shouldReschedule: false)
    }
    for (_, renderView) in attachedRenderViews {
      renderView.setPlayer(nil)
    }
    attachedRenderViews.removeAll()
    sourcesByIndex.removeAll()
    preloadedAssets.removeAll()
    metricsByController.removeAll()
    creationOrder.removeAll()
    drainPooledPlayers(keep: 0)
    positionTimer?.invalidate()
    positionTimer = nil
  }

  private func disposeControllerInternal(
    controllerId: Int,
    emitDisposed: Bool,
    shouldReschedule: Bool
  ) {
    guard let managed = controllers.removeValue(forKey: controllerId) else {
      return
    }

    creationOrder.removeAll(where: { $0 == controllerId })
    if let endObserver = managed.endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    managed.itemStatusObservation?.invalidate()
    managed.timeControlObservation?.invalidate()
    attachedRenderViews.removeValue(forKey: controllerId)?.setPlayer(nil)
    metricsByController.removeValue(forKey: controllerId)
    recycleOrReleasePlayer(managed.player)
    if emitDisposed {
      onState(controllerId, "disposed")
    }
    stopPositionTimerIfNeeded()
    if shouldReschedule {
      schedulePreloadWindow()
    }
  }

  private func schedulePreloadWindow() {
    preloadGeneration += 1
    let generation = preloadGeneration
    let targetIndices = preloadWindowIndices()

    let stale = preloadedAssets.keys.filter { !targetIndices.contains($0) }
    for index in stale {
      preloadedAssets.removeValue(forKey: index)
    }

    for index in targetIndices.sorted() {
      guard let urlString = sourcesByIndex[index], let url = URL(string: urlString) else {
        continue
      }

      if let existing = preloadedAssets[index], existing.url == urlString {
        continue
      }

      let asset = AVURLAsset(url: url)
      let keys = ["playable", "duration"]

      asset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
        DispatchQueue.main.async {
          guard let self else {
            return
          }
          guard generation == self.preloadGeneration else {
            return
          }
          guard self.sourcesByIndex[index] == urlString else {
            self.preloadedAssets.removeValue(forKey: index)
            return
          }

          var playableError: NSError?
          let playableStatus = asset.statusOfValue(
            forKey: "playable",
            error: &playableError
          )

          if playableStatus == .loaded || playableStatus == .unknown {
            self.preloadedAssets[index] = PreloadedAsset(url: urlString, asset: asset)
          } else {
            self.preloadedAssets.removeValue(forKey: index)
          }
        }
      }
    }
  }

  private func preloadWindowIndices() -> Set<Int> {
    guard preloadCount > 0, !sourcesByIndex.isEmpty else {
      return []
    }

    guard let minIndex = sourcesByIndex.keys.min(),
      let maxIndex = sourcesByIndex.keys.max()
    else {
      return []
    }

    let start = max(minIndex, visibleIndex - preloadCount)
    let end = min(maxIndex, visibleIndex + preloadCount)
    if start > end {
      return []
    }
    return Set(start...end)
  }

  private func enforceVisibleWindowEviction(forceAggressive: Bool = false) {
    guard !controllers.isEmpty else {
      return
    }

    let radius = forceAggressive ? 0 : activeWindowRadius
    let start = visibleIndex - radius
    let end = visibleIndex + radius
    let toEvict = controllers
      .filter { (_, managed) in
        managed.index >= 0 && (managed.index < start || managed.index > end)
      }
      .keys

    for controllerId in toEvict {
      disposeControllerInternal(
        controllerId: controllerId,
        emitDisposed: true,
        shouldReschedule: false
      )
    }
  }

  private func evictToPoolSizeIfNeeded() {
    while controllers.count >= maxCachedPlayers {
      guard let candidate = evictionCandidateId() else {
        break
      }
      disposeControllerInternal(controllerId: candidate, emitDisposed: true, shouldReschedule: false)
    }
  }

  private func evictionCandidateId() -> Int? {
    if let outsideWindowId = creationOrder.first(where: { id in
      guard let managed = controllers[id], managed.index >= 0 else {
        return false
      }
      let distance = abs(managed.index - visibleIndex)
      return distance > activeWindowRadius
    }) {
      return outsideWindowId
    }

    return creationOrder.first
  }

  private func attachObservers(to managed: ManagedController, playerItem: AVPlayerItem) {
    managed.itemStatusObservation = playerItem.observe(
      \.status,
      options: [.new, .initial]
    ) { [weak self] item, _ in
      guard let self = self else {
        return
      }
      switch item.status {
      case .readyToPlay:
        if var metrics = self.metricsByController[managed.id] {
          metrics.hasReady = true
          self.metricsByController[managed.id] = metrics
          self.emitMetrics(managed.id)
        }
        self.onState(managed.id, "ready")
      case .failed:
        self.onState(managed.id, "error")
      case .unknown:
        self.onState(managed.id, "preparing")
      @unknown default:
        self.onState(managed.id, "error")
      }
    }

    managed.timeControlObservation = managed.player.observe(
      \.timeControlStatus,
      options: [.new, .initial]
    ) { [weak self] player, _ in
      guard let self = self else {
        return
      }
      switch player.timeControlStatus {
      case .paused:
        let state = player.currentItem?.status == .readyToPlay ? "paused" : "idle"
        self.onState(managed.id, state)
      case .waitingToPlayAtSpecifiedRate:
        if var metrics = self.metricsByController[managed.id], metrics.hasReady {
          metrics.rebufferCount += 1
          self.metricsByController[managed.id] = metrics
          self.emitMetrics(managed.id)
        }
        self.onState(managed.id, "buffering")
      case .playing:
        if var metrics = self.metricsByController[managed.id] {
          metrics.hasReady = true
          if metrics.firstFrameLatencyMs == nil {
            let latency = max(0, AVPlayerManager.currentUptimeMs() - metrics.createdAtMs)
            metrics.firstFrameLatencyMs = latency
          }
          self.metricsByController[managed.id] = metrics
          self.emitMetrics(managed.id)
        }
        self.onState(managed.id, "playing")
      @unknown default:
        self.onState(managed.id, "error")
      }
    }

    managed.endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self, weak player = managed.player] _ in
      guard let self = self else {
        return
      }
      if managed.looping {
        player?.seek(to: .zero)
        player?.play()
        self.onState(managed.id, "playing")
      } else {
        self.onState(managed.id, "completed")
      }
    }
  }

  private func startPositionTimerIfNeeded() {
    guard positionTimer == nil else {
      return
    }

    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.emitPositions()
    }
    RunLoop.main.add(timer, forMode: .common)
    positionTimer = timer
  }

  private func stopPositionTimerIfNeeded() {
    guard controllers.isEmpty else {
      return
    }
    positionTimer?.invalidate()
    positionTimer = nil
  }

  private func emitPositions() {
    for (controllerId, managed) in controllers {
      updateAccessLogMetrics(controllerId: controllerId, item: managed.player.currentItem)
      let seconds = managed.player.currentTime().seconds
      guard seconds.isFinite, seconds >= 0 else {
        continue
      }
      onPosition(controllerId, Int64(seconds * 1000))
    }
  }

  private func emitMetrics(_ controllerId: Int) {
    guard let metrics = metricsByController[controllerId] else {
      return
    }
    let payload: [String: Any] = [
      "controllerId": controllerId,
      "rebufferCount": metrics.rebufferCount,
      "droppedFramesEstimate": metrics.droppedFramesEstimate,
      "firstFrameLatencyMs": metrics.firstFrameLatencyMs as Any,
      "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
    ]
    onMetrics(controllerId, payload)
  }

  private func updateAccessLogMetrics(controllerId: Int, item: AVPlayerItem?) {
    guard let item,
      var metrics = metricsByController[controllerId],
      let events = item.accessLog()?.events,
      !events.isEmpty
    else {
      return
    }

    var droppedTotal = 0
    for event in events {
      droppedTotal += max(0, Int(event.numberOfDroppedVideoFrames))
    }

    if droppedTotal != metrics.droppedFramesEstimate {
      metrics.droppedFramesEstimate = droppedTotal
      metricsByController[controllerId] = metrics
      emitMetrics(controllerId)
    }
  }

  private func obtainReusablePlayer() -> AVPlayer {
    if let player = pooledPlayers.popLast() {
      return player
    }
    return AVPlayer()
  }

  private func recycleOrReleasePlayer(_ player: AVPlayer) {
    player.pause()
    player.replaceCurrentItem(with: nil)
    player.actionAtItemEnd = .pause
    if pooledPlayers.count < maxPooledPlayers {
      pooledPlayers.append(player)
    }
  }

  private func drainPooledPlayers(keep: Int) {
    while pooledPlayers.count > keep {
      _ = pooledPlayers.popLast()
    }
  }

  private static func currentUptimeMs() -> Int64 {
    Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
  }
}
