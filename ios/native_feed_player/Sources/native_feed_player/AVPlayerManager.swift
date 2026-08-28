import AVFoundation
import Foundation
import UIKit

/// Owns `AVPlayer` instances, preload scheduling, and eviction.
final class AVPlayerManager {
  typealias StateCallback = (
    _ controllerId: Int, _ status: PlaybackStatusMessage, _ error: PlaybackErrorMessage?
  ) -> Void
  typealias ReleasedCallback = (_ controllerId: Int, _ reason: ReleaseReasonMessage) -> Void
  typealias PositionCallback = (_ event: PositionEvent) -> Void
  typealias MetricsCallback = (_ event: MetricsEvent) -> Void
  typealias VideoSizeCallback = (_ event: VideoSizeEvent) -> Void

  /// Playback setup failure reported to Dart.
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
    let player: AVQueuePlayer
    let looping: Bool
    /// Retained for the lifetime of gapless looping.
    var looper: AVPlayerLooper?
    /// Creation-time visibility generation used to defer eviction.
    let createdAtVisibleGeneration: Int
    var itemStatusObservation: NSKeyValueObservation?
    var timeControlObservation: NSKeyValueObservation?
    var readyForDisplayObservation: NSKeyValueObservation?
    var presentationSizeObservation: NSKeyValueObservation?
    var endObserver: NSObjectProtocol?

    init(
      id: Int,
      sourceId: String,
      player: AVQueuePlayer,
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
  private let onVideoSize: VideoSizeCallback

  private let registry = FeedSourceRegistry()
  private let resourceLoader = CachingResourceLoader()
  private let resourceLoaderQueue = DispatchQueue(label: "native_feed_player.loader.delegate")
  private var controllers: [Int: ManagedController] = [:]
  private var creationOrder: [Int] = []
  private var preparedItems: [String: PreparedItem] = [:]
  private var metricsByController: [Int: PlaybackMetrics] = [:]
  /// Reusable queue players required by `AVPlayerLooper`.
  private var pooledPlayers: [AVQueuePlayer] = []
  private var attachedRenderViews: [Int: NativeVideoRenderView] = [:]

  private var maxActivePlayers: Int = 3
  private var preloadAhead: Int = 2
  private var preloadBehind: Int = 1
  private var maxConcurrentPreloads: Int = 2
  private var positionInterval: TimeInterval = 0.2
  private var muted: Bool = false
  private var volume: Float = 1.0
  private var handleAudioFocus: Bool = true

  /// Controllers paused by backgrounding, to be resumed on return.
  private var autoPausedControllerIds = Set<Int>()
  private var pendingRateByController: [Int: Float] = [:]
  private var backgroundObserver: NSObjectProtocol?
  private var foregroundObserver: NSObjectProtocol?
  private var visibleGeneration: Int = 0
  private var preloadGeneration: Int = 0
  private var positionTimer: Timer?

  /// Preload-window multiplier reduced under rebuffer or memory pressure.
  private var windowScale: Double = 1.0
  private var rebuffersSinceLastRecovery: Int = 0

  /// Stalls before preload degradation.
  private static let rebuffersBeforeDegrade = 3

  /// Minimum preload-window multiplier.
  private static let minWindowScale = 0.25

  /// Maximum combined active and pooled player count.
  private var maxTotalPlayers: Int = 6

  private func totalLivePlayers() -> Int {
    controllers.count + pooledPlayers.count
  }

  init(
    onState: @escaping StateCallback,
    onReleased: @escaping ReleasedCallback,
    onPosition: @escaping PositionCallback,
    onMetrics: @escaping MetricsCallback,
    onVideoSize: @escaping VideoSizeCallback
  ) {
    self.onState = onState
    self.onReleased = onReleased
    self.onPosition = onPosition
    self.onMetrics = onMetrics
    self.onVideoSize = onVideoSize
    observeAppLifecycle()
  }

  deinit {
    disposeAll()
  }

  func initialize(config: FeedPlayerConfigMessage) {
    resetSession(reason: .disposed)
    maxActivePlayers = max(1, Int(config.maxActivePlayers))
    preloadAhead = max(0, Int(config.preloadAhead))
    preloadBehind = max(0, Int(config.preloadBehind))
    maxConcurrentPreloads = max(1, Int(config.maxConcurrentPreloads))
    positionInterval = max(0.05, Double(config.positionUpdateIntervalMs) / 1000.0)
    applyAudioPolicy(config.audio)
    maxTotalPlayers = maxActivePlayers + preloadAhead + preloadBehind + 1

    MediaDiskCache.shared.configure(
      enabled: config.cache.enabled,
      maxBytes: config.cache.maxBytes
    )

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
    player.removeAllItems()
    player.insert(item, after: nil)
    player.automaticallyWaitsToMinimizeStalling = true
    player.volume = muted ? 0 : volume

    let managed = ManagedController(
      id: controllerId,
      sourceId: sourceId,
      player: player,
      looping: looping,
      createdAtVisibleGeneration: visibleGeneration
    )

    if looping {
      // AVPlayerLooper schedules gapless repeats.
      managed.looper = AVPlayerLooper(player: player, templateItem: item)
      player.actionAtItemEnd = .advance
    } else {
      player.actionAtItemEnd = .pause
    }

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

    // Apply eviction after controller registration.
    enforceVisibleWindowEviction()
    enforceTotalPlayerBudget(protectedControllerId: controllerId)
    schedulePreloadWindow()
  }

  func play(controllerId: Int) {
    autoPausedControllerIds.remove(controllerId)
    controllers[controllerId]?.player.play()
  }

  func pause(controllerId: Int) {
    autoPausedControllerIds.remove(controllerId)
    controllers[controllerId]?.player.pause()
  }

  // MARK: - Controls

  func setVolume(controllerId: Int, value: Double) {
    let clamped = min(max(Float(value), 0), 1)
    controllers[controllerId]?.player.volume = muted ? 0 : clamped
  }

  func setMuted(controllerId: Int, value: Bool) {
    controllers[controllerId]?.player.volume = value ? 0 : volume
  }

  func setPlaybackSpeed(controllerId: Int, speed: Double) {
    guard let player = controllers[controllerId]?.player else {
      return
    }
    let clamped = min(max(Float(speed), 0.25), 4)
    // Defer rate changes until playback is active.
    if player.timeControlStatus == .playing {
      player.rate = clamped
    }
    pendingRateByController[controllerId] = clamped
  }

  func setLooping(controllerId: Int, looping: Bool) {
    guard let managed = controllers[controllerId] else {
      return
    }
    if looping {
      guard managed.looper == nil, let item = managed.player.currentItem else {
        return
      }
      managed.looper = AVPlayerLooper(player: managed.player, templateItem: item)
      managed.player.actionAtItemEnd = .advance
    } else {
      managed.looper?.disableLooping()
      managed.looper = nil
      managed.player.actionAtItemEnd = .pause
    }
  }

  /// Applies audio policy to current and future players.
  func applyAudioPolicy(_ policy: AudioPolicyMessage) {
    muted = policy.muted
    volume = min(max(Float(policy.volume), 0), 1)
    handleAudioFocus = policy.handleAudioFocus && !policy.muted

    configureAudioSession()
    for managed in controllers.values {
      managed.player.volume = muted ? 0 : volume
    }
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      if muted {
        // Preserve external audio while muted.
        try session.setCategory(.ambient, mode: .moviePlayback, options: [.mixWithOthers])
      } else if handleAudioFocus {
        try session.setCategory(.playback, mode: .moviePlayback)
      } else {
        try session.setCategory(
          .playback,
          mode: .moviePlayback,
          options: [.mixWithOthers]
        )
      }
      try session.setActive(true, options: [])
    } catch {
      // Audio-session failure does not stop playback.
    }
  }

  // MARK: - App lifecycle

  private func observeAppLifecycle() {
    let center = NotificationCenter.default
    backgroundObserver = center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.onAppBackgrounded()
    }
    foregroundObserver = center.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.onAppForegrounded()
    }
  }

  /// Pauses active players until the app returns to the foreground.
  private func onAppBackgrounded() {
    for (controllerId, managed) in controllers
    where managed.player.timeControlStatus == .playing {
      autoPausedControllerIds.insert(controllerId)
      managed.player.pause()
    }
  }

  private func onAppForegrounded() {
    for controllerId in autoPausedControllerIds {
      controllers[controllerId]?.player.play()
    }
    autoPausedControllerIds.removeAll()
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
    if let previous = attachedRenderViews[controllerId], previous !== renderView {
      previous.setPlayer(nil)
    }
    attachedRenderViews[controllerId] = renderView
    if let managed = controllers[controllerId] {
      bindRenderView(renderView, to: managed)
    } else {
      renderView.setPlayer(nil)
    }
  }

  /// Returns the player used for texture output.
  func player(for controllerId: Int) -> AVPlayer? {
    controllers[controllerId]?.player
  }

  func detach(controllerId: Int, renderView expected: NativeVideoRenderView? = nil) {
    guard let renderView = attachedRenderViews[controllerId] else {
      expected?.setPlayer(nil)
      return
    }
    if let expected, renderView !== expected {
      expected.setPlayer(nil)
      return
    }
    attachedRenderViews.removeValue(forKey: controllerId)
    controllers[controllerId]?.readyForDisplayObservation?.invalidate()
    controllers[controllerId]?.readyForDisplayObservation = nil
    renderView.setPlayer(nil)
  }

  func onMemoryWarning() {
    preloadGeneration += 1
    windowScale = AVPlayerManager.minWindowScale
    preparedItems.removeAll()
    drainPooledPlayers(keep: 0)
    enforceVisibleWindowEviction(forceAggressive: true)
  }

  /// Reduces the preload window after repeated stalls.
  private func noteRebuffer() {
    rebuffersSinceLastRecovery += 1
    guard rebuffersSinceLastRecovery >= AVPlayerManager.rebuffersBeforeDegrade else {
      return
    }
    rebuffersSinceLastRecovery = 0
    let next = max(windowScale / 2, AVPlayerManager.minWindowScale)
    if next != windowScale {
      windowScale = next
      schedulePreloadWindow()
    }
  }

  /// Restores the preload window after stable playback.
  private func noteSteadyPlayback() {
    rebuffersSinceLastRecovery = 0
    guard windowScale < 1.0 else {
      return
    }
    windowScale = min(windowScale * 2, 1.0)
    schedulePreloadWindow()
  }

  func disposeAll() {
    resetSession(reason: .engineDetached)
  }

  private func resetSession(reason: ReleaseReasonMessage) {
    preloadGeneration += 1
    resourceLoader.cancelAll()
    for controllerId in Array(controllers.keys) {
      disposeControllerInternal(
        controllerId: controllerId,
        reason: reason,
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
    autoPausedControllerIds.removeAll()
    pendingRateByController.removeAll()
    visibleGeneration = 0
    windowScale = 1.0
    rebuffersSinceLastRecovery = 0
    drainPooledPlayers(keep: 0)
    positionTimer?.invalidate()
    positionTimer = nil
  }

  // MARK: - Prebuffering

  /// Prepares items in the current preload window.
  private func schedulePreloadWindow() {
    preloadGeneration += 1
    let generation = preloadGeneration
    let window = registry.preloadWindow(
      ahead: preloadAhead,
      behind: preloadBehind,
      scale: windowScale
    )
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
        // Scale buffering by viewport distance.
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

  /// Prerolls a ready player before presentation.
  private func prerollIfReady(_ player: AVPlayer) {
    guard player.status == .readyToPlay else {
      return
    }
    player.preroll(atRate: 1.0, completionHandler: nil)
  }

  private func takePreparedItem(for source: RegisteredSource) -> AVPlayerItem? {
    guard let prepared = preparedItems[source.id], prepared.uri == source.uri else {
      preparedItems.removeValue(forKey: source.id)
      return nil
    }
    preparedItems.removeValue(forKey: source.id)
    return prepared.item
  }

  /// Creates a cached progressive item or a network-backed HLS item.
  private func makePlayerItem(for source: RegisteredSource) -> AVPlayerItem {
    guard let url = URL(string: source.uri) else {
      return AVPlayerItem(asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")))
    }

    let asset: AVURLAsset
    if shouldCache(source),
      let interceptURL = CachingResourceLoader.interceptURL(for: source.uri)
    {
      resourceLoader.setHeaders(source.headers, for: source.uri)
      asset = AVURLAsset(url: interceptURL)
      asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoaderQueue)
    } else {
      var options: [String: Any] = [:]
      if !source.headers.isEmpty {
        // AVURLAsset option for per-source HTTP headers.
        options["AVURLAssetHTTPHeaderFieldsKey"] = source.headers
      }
      asset = AVURLAsset(url: url, options: options)
    }

    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 4
    return item
  }

  private func shouldCache(_ source: RegisteredSource) -> Bool {
    guard MediaDiskCache.shared.isEnabled else {
      return false
    }
    switch source.kind {
    case .hls:
      return false
    case .progressive:
      return true
    case .auto:
      // Infer HLS from playlist extensions.
      let lowered = source.uri.lowercased()
      return !lowered.contains(".m3u8") && !lowered.contains(".mpd")
    }
  }

  // MARK: - Cache

  func clearMediaCache() {
    MediaDiskCache.shared.evictAll()
  }

  /// Evicts the given sources, or everything when `sourceIds` is empty.
  func evictCachedMedia(_ sourceIds: [String]) {
    guard !sourceIds.isEmpty else {
      MediaDiskCache.shared.evictAll()
      return
    }
    for sourceId in sourceIds {
      guard let uri = registry.source(id: sourceId)?.uri else {
        continue
      }
      MediaDiskCache.shared.evict(uri: uri)
    }
  }

  func cacheStatus(sourceId: String) -> CacheStatusMessage {
    guard let uri = registry.source(id: sourceId)?.uri else {
      return CacheStatusMessage(
        sourceId: sourceId,
        cachedBytes: 0,
        totalBytes: 0,
        isComplete: false
      )
    }
    // Whole-file cache entries are complete.
    let bytes = MediaDiskCache.shared.cachedBytes(for: uri)
    return CacheStatusMessage(
      sourceId: sourceId,
      cachedBytes: bytes,
      totalBytes: bytes,
      isComplete: bytes > 0
    )
  }

  func cacheUsageBytes() -> Int64 {
    MediaDiskCache.shared.usageBytes()
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

  /// Enforces the player budget by releasing pooled players first.
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

  /// Selects the furthest controller outside `protectedSourceId`.
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
    managed.presentationSizeObservation?.invalidate()
    autoPausedControllerIds.remove(controllerId)
    pendingRateByController.removeValue(forKey: controllerId)
    // Stop the looper before recycling its player.
    managed.looper?.disableLooping()
    managed.looper = nil
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

    // Match Android's first-frame metric at display readiness.
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
        self.prerollIfReady(managed.player)
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
          self.noteRebuffer()
          self.emitMetrics(managed.id)
        }
        self.onState(managed.id, .buffering, nil)
      case .playing:
        if var metrics = self.metricsByController[managed.id] {
          metrics.hasBeenReady = true
          self.metricsByController[managed.id] = metrics
        }
        // Apply deferred playback speed after playback starts.
        if let rate = self.pendingRateByController[managed.id], player.rate != rate {
          player.rate = rate
        }
        self.noteSteadyPlayback()
        self.onState(managed.id, .playing, nil)
      @unknown default:
        self.onState(
          managed.id,
          .error,
          PlaybackErrorMapper.unknown(message: "Unrecognised timeControlStatus")
        )
      }
    }

    managed.presentationSizeObservation = playerItem.observe(
      \.presentationSize,
      options: [.new, .initial]
    ) { [weak self] item, _ in
      let size = item.presentationSize
      guard size.width > 0, size.height > 0 else {
        return
      }
      // AVFoundation reports display-oriented dimensions.
      self?.onVideoSize(
        VideoSizeEvent(
          controllerId: Int64(managed.id),
          width: Int64(size.width),
          height: Int64(size.height),
          rotationDegrees: 0
        )
      )
    }

    // AVPlayerLooper handles item completion for looping playback.
    guard !managed.looping else {
      return
    }
    managed.endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self] _ in
      self?.onState(managed.id, .completed, nil)
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
      // Skip position updates for idle offscreen players.
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

  /// Accumulates access-log dropped frames into a lifetime total.
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

  private func obtainReusablePlayer() -> AVQueuePlayer {
    if let player = pooledPlayers.popLast() {
      return player
    }
    return AVQueuePlayer()
  }

  private func recycleOrReleasePlayer(_ player: AVQueuePlayer) {
    player.pause()
    player.removeAllItems()
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
