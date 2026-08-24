import AVFoundation
import Foundation

/// AVPlayer lifecycle and event orchestration for native feed playback.
///
/// Controllers are addressed by id and bound to a `RegisteredSource`; feed
/// position is only used to rank preload priority and eviction distance.
final class AVPlayerManager {
  typealias StateCallback = (
    _ controllerId: Int, _ status: PlaybackStatusMessage, _ error: PlaybackErrorMessage?
  ) -> Void
  typealias ReleasedCallback = (_ controllerId: Int, _ reason: ReleaseReasonMessage) -> Void
  typealias PositionCallback = (_ event: PositionEvent) -> Void
  typealias MetricsCallback = (_ event: MetricsEvent) -> Void

  /// Structured failure surfaced to Dart instead of a blanket `create_failed`.
  struct PlaybackSetupError: LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
  }

  private struct PreparedItem {
    let sourceId: String
    let uri: String
    let item: AVPlayerItem
  }

  private struct PlaybackMetrics {
    let createdAtMs: Int64 = AVPlayerManager.currentUptimeMs()
    var firstFrameLatencyMs: Int64?
    var rebufferCount: Int = 0
    var droppedFrames: Int = 0
    var hasBeenReady: Bool = false
  }

  private final class ManagedController {
    let id: Int
    let sourceId: String
    let player: AVPlayer
    let looping: Bool
    /// Value of `visibleGeneration` when this controller was created. Window
    /// eviction ignores controllers created since the last visible-source
    /// update, because they have not been measured against a current window.
    let createdAtVisibleGeneration: Int
    var itemStatusObservation: NSKeyValueObservation?
    var timeControlObservation: NSKeyValueObservation?
    var readyForDisplayObservation: NSKeyValueObservation?
    var endObserver: NSObjectProtocol?

    init(
      id: Int,
      sourceId: String,
      player: AVPlayer,
      looping: Bool,
      createdAtVisibleGeneration: Int
    ) {
      self.id = id
      self.sourceId = sourceId
      self.player = player
      self.looping = looping
      self.createdAtVisibleGeneration = createdAtVisibleGeneration
    }
  }

  private let onState: StateCallback
  private let onReleased: ReleasedCallback
  private let onPosition: PositionCallback
  private let onMetrics: MetricsCallback

  private let registry = FeedSourceRegistry()
  private var controllers: [Int: ManagedController] = [:]
  private var creationOrder: [Int] = []
  private var preparedItems: [String: PreparedItem] = [:]
  private var metricsByController: [Int: PlaybackMetrics] = [:]
  private var pooledPlayers: [AVPlayer] = []
  private var attachedRenderViews: [Int: NativeVideoRenderView] = [:]

  private var maxActivePlayers: Int = 3
  private var preloadAhead: Int = 2
  private var preloadBehind: Int = 1
  private var maxConcurrentPreloads: Int = 2
  private var positionInterval: TimeInterval = 0.2
  private var muted: Bool = true
  private var volume: Float = 1.0
  private var visibleGeneration: Int = 0
  private var preloadGeneration: Int = 0
  private var positionTimer: Timer?

  /// Ceiling on every AVPlayer kept alive across the active and pooled buckets
  /// combined; capping each bucket alone lets their sum grow freely.
  private var maxTotalPlayers: Int = 6

  private func totalLivePlayers() -> Int {
    controllers.count + pooledPlayers.count
  }

  init(
    onState: @escaping StateCallback,
    onReleased: @escaping ReleasedCallback,
    onPosition: @escaping PositionCallback,
    onMetrics: @escaping MetricsCallback
  ) {
    self.onState = onState
    self.onReleased = onReleased
    self.onPosition = onPosition
    self.onMetrics = onMetrics
  }

  deinit {
    disposeAll()
  }

  func initialize(config: FeedPlayerConfigMessage) {
    maxActivePlayers = max(1, Int(config.maxActivePlayers))
    preloadAhead = max(0, Int(config.preloadAhead))
    preloadBehind = max(0, Int(config.preloadBehind))
    maxConcurrentPreloads = max(1, Int(config.maxConcurrentPreloads))
    positionInterval = max(0.05, Double(config.positionUpdateIntervalMs) / 1000.0)
    muted = config.audio.muted
    volume = min(max(Float(config.audio.volume), 0), 1)
    maxTotalPlayers = maxActivePlayers + preloadAhead + preloadBehind + 1

    preloadGeneration += 1
    preparedItems.removeAll()
    drainPooledPlayers(keep: 0)
    enforceVisibleWindowEviction()
    schedulePreloadWindow()
    restartPositionTimerIfNeeded()
  }

  func setSources(_ sources: [RegisteredSource]) {
    registry.replaceAll(sources)
    releaseOrphanedPreparedItems()
    enforceVisibleWindowEviction()
    schedulePreloadWindow()
  }

  func appendSources(_ sources: [RegisteredSource]) {
    registry.append(sources)
    schedulePreloadWindow()
  }

  func removeSources(_ sourceIds: [String]) {
    registry.remove(ids: sourceIds)
    for sourceId in sourceIds {
      preparedItems.removeValue(forKey: sourceId)
      let ids = controllers.filter { $0.value.sourceId == sourceId }.map(\.key)
      for controllerId in ids {
        disposeControllerInternal(
          controllerId: controllerId,
          reason: .disposed,
          shouldReschedule: false
        )
      }
    }
    schedulePreloadWindow()
  }

  func createController(
    controllerId: Int,
    sourceId: String,
    autoPlay: Bool,
    looping: Bool
  ) throws {
    guard let source = registry.source(id: sourceId) else {
      throw PlaybackSetupError(
        code: "source_not_found",
        message: "No registered source with id=\(sourceId). Call setSources first."
      )
    }
    guard URL(string: source.uri) != nil else {
      throw PlaybackSetupError(
        code: "invalid_url",
        message: "Invalid URI for source \(sourceId): \(source.uri)"
      )
    }

    evictToActiveLimit(protectedSourceId: sourceId)

    let item = takePreparedItem(for: source) ?? makePlayerItem(for: source)
    let player = obtainReusablePlayer()
    player.replaceCurrentItem(with: item)
    player.actionAtItemEnd = looping ? .none : .pause
    player.automaticallyWaitsToMinimizeStalling = true
    player.volume = muted ? 0 : volume

    let managed = ManagedController(
      id: controllerId,
      sourceId: sourceId,
      player: player,
      looping: looping,
      createdAtVisibleGeneration: visibleGeneration
    )
    attachObservers(to: managed, playerItem: item)

    controllers[controllerId] = managed
    creationOrder.append(controllerId)
    metricsByController[controllerId] = PlaybackMetrics()
    emitMetrics(controllerId)
    if let renderView = attachedRenderViews[controllerId] {
      bindRenderView(renderView, to: managed)
    }
    onState(controllerId, .preparing, nil)
    startPositionTimerIfNeeded()

    if autoPlay {
      player.play()
    }

    // Runs after registration and skips this generation's new controllers, so a
    // controller requested ahead of setVisibleSource is never torn down by a
    // window it has not been measured against yet.
    enforceVisibleWindowEviction()
    enforceTotalPlayerBudget(protectedControllerId: controllerId)
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
    let time = CMTime(value: max(Int64(0), positionMs), timescale: 1000)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func disposeController(controllerId: Int) {
    disposeControllerInternal(
      controllerId: controllerId,
      reason: .disposed,
      shouldReschedule: true
    )
  }

  func setVisibleSource(_ sourceId: String) {
    registry.setVisible(sourceId)
    visibleGeneration += 1
    enforceVisibleWindowEviction()
    enforceTotalPlayerBudget()
    schedulePreloadWindow()
  }

  func attach(controllerId: Int, renderView: NativeVideoRenderView) {
    attachedRenderViews[controllerId] = renderView
    if let managed = controllers[controllerId] {
      bindRenderView(renderView, to: managed)
    } else {
      renderView.setPlayer(nil)
    }
  }

  func detach(controllerId: Int) {
    guard let renderView = attachedRenderViews.removeValue(forKey: controllerId) else {
      return
    }
    controllers[controllerId]?.readyForDisplayObservation?.invalidate()
    controllers[controllerId]?.readyForDisplayObservation = nil
    renderView.setPlayer(nil)
  }

  func onMemoryWarning() {
    preloadGeneration += 1
    preparedItems.removeAll()
    drainPooledPlayers(keep: 0)
    enforceVisibleWindowEviction(forceAggressive: true)
  }

  func disposeAll() {
    preloadGeneration += 1
    for controllerId in Array(controllers.keys) {
      disposeControllerInternal(
        controllerId: controllerId,
        reason: .engineDetached,
        shouldReschedule: false
      )
    }
    for (_, renderView) in attachedRenderViews {
      renderView.setPlayer(nil)
    }
    attachedRenderViews.removeAll()
    registry.clear()
    preparedItems.removeAll()
    metricsByController.removeAll()
    creationOrder.removeAll()
    drainPooledPlayers(keep: 0)
    positionTimer?.invalidate()
    positionTimer = nil
  }

  // MARK: - Prebuffering

  /// Builds player items for the nearby window so the next source can start
  /// without waiting on a fresh asset load.
  private func schedulePreloadWindow() {
    preloadGeneration += 1
    let generation = preloadGeneration
    let window = registry.preloadWindow(ahead: preloadAhead, behind: preloadBehind)
    let windowIds = Set(window.map(\.id))

    for sourceId in preparedItems.keys where !windowIds.contains(sourceId) {
      preparedItems.removeValue(forKey: sourceId)
    }

    var scheduled = 0
    for source in window {
      if scheduled >= maxConcurrentPreloads {
        break
      }
      if controllers.values.contains(where: { $0.sourceId == source.id }) {
        continue
      }
      if let existing = preparedItems[source.id], existing.uri == source.uri {
        continue
      }
      scheduled += 1

      DispatchQueue.main.async { [weak self] in
        guard let self, generation == self.preloadGeneration else {
          return
        }
        guard let fresh = self.registry.source(id: source.id) else {
          return
        }
        if self.preparedItems[fresh.id] != nil {
          return
        }
        let item = self.makePlayerItem(for: fresh)
        // Buffer eagerly for the nearest item, more conservatively further out.
        let distance = self.registry.distanceFromVisible(id: fresh.id) ?? self.preloadAhead
        item.preferredForwardBufferDuration = distance <= 1 ? 4 : 2
        self.preparedItems[fresh.id] = PreparedItem(
          sourceId: fresh.id,
          uri: fresh.uri,
          item: item
        )
      }
    }
  }

  private func takePreparedItem(for source: RegisteredSource) -> AVPlayerItem? {
    guard let prepared = preparedItems[source.id], prepared.uri == source.uri else {
      preparedItems.removeValue(forKey: source.id)
      return nil
    }
    preparedItems.removeValue(forKey: source.id)
    return prepared.item
  }

  private func makePlayerItem(for source: RegisteredSource) -> AVPlayerItem {
    guard let url = URL(string: source.uri) else {
      return AVPlayerItem(asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")))
    }
    var options: [String: Any] = [:]
    if !source.headers.isEmpty {
      // Undocumented but long-standing key; the only way to attach headers to a
      // remote AVURLAsset without a resource-loader shim.
      options["AVURLAssetHTTPHeaderFieldsKey"] = source.headers
    }
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 4
    return item
  }

  private func releaseOrphanedPreparedItems() {
    for sourceId in preparedItems.keys where registry.source(id: sourceId) == nil {
      preparedItems.removeValue(forKey: sourceId)
    }
  }

  // MARK: - Eviction

  private func enforceVisibleWindowEviction(forceAggressive: Bool = false) {
    guard !controllers.isEmpty, let visibleRank = registry.visibleRank() else {
      return
    }

    let keepAhead = forceAggressive ? 0 : preloadAhead
    let keepBehind = forceAggressive ? 0 : preloadBehind

    let toEvict = controllers.filter { (_, managed) in
      let rank = registry.source(id: managed.sourceId)?.rank
      let outsideWindow: Bool
      if let rank {
        let delta = rank - visibleRank
        outsideWindow = delta < -keepBehind || delta > keepAhead
      } else {
        outsideWindow = true
      }
      let measurable = forceAggressive
        || managed.createdAtVisibleGeneration != visibleGeneration
      return outsideWindow && measurable
    }.keys

    for controllerId in toEvict {
      disposeControllerInternal(
        controllerId: controllerId,
        reason: .evicted,
        shouldReschedule: false
      )
    }
  }

  /// Trims the combined player count back under `maxTotalPlayers`, draining the
  /// stateless pool before touching live controllers.
  private func enforceTotalPlayerBudget(protectedControllerId: Int? = nil) {
    while totalLivePlayers() > maxTotalPlayers, !pooledPlayers.isEmpty {
      _ = pooledPlayers.popLast()
    }

    while totalLivePlayers() > maxTotalPlayers {
      let candidate = controllers.keys
        .filter { $0 != protectedControllerId }
        .max(by: { distanceFromViewport($0) < distanceFromViewport($1) })
      guard let candidate else {
        break
      }
      disposeControllerInternal(
        controllerId: candidate,
        reason: .evicted,
        shouldReschedule: false
      )
    }
  }

  private func evictToActiveLimit(protectedSourceId: String?) {
    while controllers.count >= maxActivePlayers {
      guard let candidate = evictionCandidateId(protectedSourceId: protectedSourceId) else {
        break
      }
      disposeControllerInternal(
        controllerId: candidate,
        reason: .evicted,
        shouldReschedule: false
      )
    }
  }

  /// Picks an eviction victim, never choosing the source a controller is about
  /// to be created for.
  private func evictionCandidateId(protectedSourceId: String?) -> Int? {
    let eligible = creationOrder.filter { controllers[$0]?.sourceId != protectedSourceId }
    if let farthest = eligible.max(by: {
      distanceFromViewport($0) < distanceFromViewport($1)
    }) {
      return farthest
    }
    return eligible.first
  }

  private func distanceFromViewport(_ controllerId: Int) -> Int {
    guard let sourceId = controllers[controllerId]?.sourceId,
      let distance = registry.distanceFromVisible(id: sourceId)
    else {
      return Int.max / 4
    }
    return distance
  }

  private func disposeControllerInternal(
    controllerId: Int,
    reason: ReleaseReasonMessage,
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
    managed.readyForDisplayObservation?.invalidate()
    attachedRenderViews.removeValue(forKey: controllerId)?.setPlayer(nil)
    metricsByController.removeValue(forKey: controllerId)
    recycleOrReleasePlayer(managed.player)
    onReleased(controllerId, reason)
    stopPositionTimerIfNeeded()
    if shouldReschedule {
      schedulePreloadWindow()
    }
  }

  // MARK: - Observation

  private func bindRenderView(
    _ renderView: NativeVideoRenderView,
    to managed: ManagedController
  ) {
    renderView.setPlayer(managed.player)

    // isReadyForDisplay is the genuine first-frame signal. Observing it keeps
    // the iOS first-frame metric comparable with Android's onRenderedFirstFrame
    // rather than measuring the earlier "started playing" transition.
    managed.readyForDisplayObservation?.invalidate()
    managed.readyForDisplayObservation = renderView.playerLayer.observe(
      \.isReadyForDisplay,
      options: [.new, .initial]
    ) { [weak self] layer, _ in
      guard let self, layer.isReadyForDisplay else {
        return
      }
      self.markFirstFrame(managed.id)
    }
  }

  private func markFirstFrame(_ controllerId: Int) {
    guard var metrics = metricsByController[controllerId],
      metrics.firstFrameLatencyMs == nil
    else {
      return
    }
    metrics.firstFrameLatencyMs = max(
      0,
      AVPlayerManager.currentUptimeMs() - metrics.createdAtMs
    )
    metricsByController[controllerId] = metrics
    emitMetrics(controllerId)
  }

  private func attachObservers(to managed: ManagedController, playerItem: AVPlayerItem) {
    managed.itemStatusObservation = playerItem.observe(
      \.status,
      options: [.new, .initial]
    ) { [weak self] item, _ in
      guard let self else {
        return
      }
      switch item.status {
      case .readyToPlay:
        if var metrics = self.metricsByController[managed.id] {
          metrics.hasBeenReady = true
          self.metricsByController[managed.id] = metrics
          self.emitMetrics(managed.id)
        }
        self.onState(managed.id, .ready, nil)
      case .failed:
        self.onState(
          managed.id,
          .error,
          PlaybackErrorMapper.map(item.error, sourceId: managed.sourceId)
        )
      case .unknown:
        self.onState(managed.id, .preparing, nil)
      @unknown default:
        self.onState(
          managed.id,
          .error,
          PlaybackErrorMapper.unknown(message: "Unrecognised AVPlayerItem status")
        )
      }
    }

    managed.timeControlObservation = managed.player.observe(
      \.timeControlStatus,
      options: [.new, .initial]
    ) { [weak self] player, _ in
      guard let self else {
        return
      }
      switch player.timeControlStatus {
      case .paused:
        let ready = player.currentItem?.status == .readyToPlay
        self.onState(managed.id, ready ? .paused : .idle, nil)
      case .waitingToPlayAtSpecifiedRate:
        if var metrics = self.metricsByController[managed.id], metrics.hasBeenReady {
          metrics.rebufferCount += 1
          self.metricsByController[managed.id] = metrics
          self.emitMetrics(managed.id)
        }
        self.onState(managed.id, .buffering, nil)
      case .playing:
        if var metrics = self.metricsByController[managed.id] {
          metrics.hasBeenReady = true
          self.metricsByController[managed.id] = metrics
        }
        self.onState(managed.id, .playing, nil)
      @unknown default:
        self.onState(
          managed.id,
          .error,
          PlaybackErrorMapper.unknown(message: "Unrecognised timeControlStatus")
        )
      }
    }

    managed.endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self, weak player = managed.player] _ in
      guard let self else {
        return
      }
      if managed.looping {
        player?.seek(to: .zero)
        player?.play()
        self.onState(managed.id, .playing, nil)
      } else {
        self.onState(managed.id, .completed, nil)
      }
    }
  }

  // MARK: - Timers and emission

  private func startPositionTimerIfNeeded() {
    guard positionTimer == nil else {
      return
    }
    let timer = Timer(timeInterval: positionInterval, repeats: true) { [weak self] _ in
      self?.emitPositions()
    }
    RunLoop.main.add(timer, forMode: .common)
    positionTimer = timer
  }

  private func restartPositionTimerIfNeeded() {
    guard positionTimer != nil else {
      return
    }
    positionTimer?.invalidate()
    positionTimer = nil
    startPositionTimerIfNeeded()
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
      // Offscreen, idle players do not need per-tick position traffic. A
      // controller is interesting only if it renders somewhere or is playing.
      let isRendering = attachedRenderViews[controllerId] != nil
      let isPlaying = managed.player.timeControlStatus == .playing
      guard isRendering || isPlaying else {
        continue
      }

      updateDroppedFrames(controllerId: controllerId, item: managed.player.currentItem)

      let seconds = managed.player.currentTime().seconds
      guard seconds.isFinite, seconds >= 0 else {
        continue
      }

      let item = managed.player.currentItem
      onPosition(
        PositionEvent(
          controllerId: Int64(controllerId),
          positionMs: Int64(seconds * 1000),
          bufferedPositionMs: bufferedPositionMs(for: item),
          durationMs: durationMs(for: item)
        )
      )
    }
  }

  private func bufferedPositionMs(for item: AVPlayerItem?) -> Int64? {
    guard let range = item?.loadedTimeRanges.last?.timeRangeValue else {
      return nil
    }
    let end = (range.start + range.duration).seconds
    guard end.isFinite, end >= 0 else {
      return nil
    }
    return Int64(end * 1000)
  }

  private func durationMs(for item: AVPlayerItem?) -> Int64? {
    guard let seconds = item?.duration.seconds, seconds.isFinite, seconds > 0 else {
      return nil
    }
    return Int64(seconds * 1000)
  }

  private func emitMetrics(_ controllerId: Int) {
    guard let metrics = metricsByController[controllerId] else {
      return
    }
    onMetrics(
      MetricsEvent(
        controllerId: Int64(controllerId),
        rebufferCount: Int64(metrics.rebufferCount),
        droppedFrames: Int64(metrics.droppedFrames),
        timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
        firstFrameLatencyMs: metrics.firstFrameLatencyMs
      )
    )
  }

  /// Access-log events report per-interval counts, so they are summed into a
  /// lifetime total to match Android's accumulated dropped-frame counter.
  private func updateDroppedFrames(controllerId: Int, item: AVPlayerItem?) {
    guard let item,
      var metrics = metricsByController[controllerId],
      let events = item.accessLog()?.events,
      !events.isEmpty
    else {
      return
    }

    let total = events.reduce(0) { partial, event in
      partial + max(0, Int(event.numberOfDroppedVideoFrames))
    }

    if total != metrics.droppedFrames {
      metrics.droppedFrames = total
      metricsByController[controllerId] = metrics
      emitMetrics(controllerId)
    }
  }

  // MARK: - Player pooling

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
    if pooledPlayers.count < maxActivePlayers {
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
