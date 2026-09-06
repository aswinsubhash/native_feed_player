import AVFoundation
import Foundation
import UIKit

/// Time-based adaptive preload policy shared by playback signals.
/// Repeated stalls reduce the window, while each recovery step requires a
/// sustained interval of playback rather than a single `.playing` KVO event.
struct AdaptivePreloadPolicy {
  static let rebuffersBeforeDegrade = 3
  static let minimumScale = 0.25
  static let stableRecoveryIntervalMs: Int64 = 15_000

  private(set) var scale = 1.0
  private var rebuffersSinceDegrade = 0
  private var stableSinceMs: Int64?

  @discardableResult
  mutating func noteRebuffer(at _: Int64) -> Bool {
    stableSinceMs = nil
    rebuffersSinceDegrade += 1
    guard rebuffersSinceDegrade >= Self.rebuffersBeforeDegrade else {
      return false
    }
    rebuffersSinceDegrade = 0
    let next = max(scale / 2, Self.minimumScale)
    guard next != scale else {
      return false
    }
    scale = next
    return true
  }

  @discardableResult
  mutating func notePlaybackProgress(at uptimeMs: Int64) -> Bool {
    guard let stableSinceMs else {
      self.stableSinceMs = uptimeMs
      return false
    }
    guard uptimeMs - stableSinceMs >= Self.stableRecoveryIntervalMs else {
      return false
    }
    rebuffersSinceDegrade = 0
    self.stableSinceMs = uptimeMs
    guard scale < 1 else {
      return false
    }
    scale = min(scale * 2, 1)
    return true
  }

  @discardableResult
  mutating func noteMemoryPressure(at _: Int64) -> Bool {
    let changed = scale != Self.minimumScale
    scale = Self.minimumScale
    rebuffersSinceDegrade = 0
    stableSinceMs = nil
    return changed
  }

  mutating func reset() {
    scale = 1
    rebuffersSinceDegrade = 0
    stableSinceMs = nil
  }
}

/// Owns `AVPlayer` instances, preload scheduling, and eviction.
/// All mutable manager state is owned by the main dispatch queue.
final class AVPlayerManager {
  typealias LoopAssetLoader = (AVAsset, @escaping (Result<CMTime, Error>) -> Void) -> Void

  final class DroppedFrameAccumulator {
    private let samples = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()
    private(set) var total = 0

    func contains(item: AnyObject) -> Bool {
      samples.object(forKey: item) != nil
    }

    func track(item: AnyObject) {
      if !contains(item: item) {
        samples.setObject(0, forKey: item)
      }
    }

    func record(item: AnyObject, droppedFrames: Int) {
      let sample = max(0, droppedFrames)
      let previous = samples.object(forKey: item)?.intValue ?? 0
      total += sample >= previous ? sample - previous : sample
      samples.setObject(NSNumber(value: sample), forKey: item)
    }
  }
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
    let requestIdentity: String
    let playbackIdentity: String
    let sourceKind: FeedMediaKindMessage
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
    let requestIdentity: String
    let resourceIdentity: String
    let playbackIdentity: String
    let sourceKind: FeedMediaKindMessage
    let player: AVQueuePlayer
    let originalItem: AVPlayerItem
    var looping: Bool
    var targetVolume: Float
    var isMuted: Bool
    /// Retained for the lifetime of gapless looping.
    var looper: AVPlayerLooper?
    /// Creation-time visibility generation used to defer eviction.
    let createdAtVisibleGeneration: Int
    var itemStatusObservation: NSKeyValueObservation?
    var playerStatusObservation: NSKeyValueObservation?
    var timeControlObservation: NSKeyValueObservation?
    var looperStatusObservation: NSKeyValueObservation?
    var readyForDisplayObservation: NSKeyValueObservation?
    var presentationSizeObservation: NSKeyValueObservation?
    var bufferEmptyObservation: NSKeyValueObservation?
    var loadedRangesObservation: NSKeyValueObservation?
    var stalledObserver: NSObjectProtocol?
    var playbackRecoveryPending = false
    var isBuffering = false
    var hasStartedPlayback = false
    var endObserver: NSObjectProtocol?
    var accessLogObserver: NSObjectProtocol?
    var currentItemObservation: NSKeyValueObservation?
    var observedItem: AVPlayerItem?
    let droppedFrames = DroppedFrameAccumulator()
    var wantsToPlay = false
    var isConfiguringLoop = false
    var pendingSeek: CMTime?
    var seekTarget: CMTime?
    var isSeeking = false
    var seekOperationGeneration = 0
    var observerSetupDepth = 0
    var loopOperationGeneration = 0
    var didEmitReady = false
    var didReportPlaybackError = false

    init(
      id: Int,
      sourceId: String,
      requestIdentity: String,
      resourceIdentity: String,
      playbackIdentity: String,
      sourceKind: FeedMediaKindMessage,
      player: AVQueuePlayer,
      originalItem: AVPlayerItem,
      looping: Bool,
      targetVolume: Float,
      isMuted: Bool,
      createdAtVisibleGeneration: Int
    ) {
      self.id = id
      self.sourceId = sourceId
      self.requestIdentity = requestIdentity
      self.resourceIdentity = resourceIdentity
      self.playbackIdentity = playbackIdentity
      self.sourceKind = sourceKind
      self.player = player
      self.originalItem = originalItem
      self.looping = looping
      self.targetVolume = targetVolume
      self.isMuted = isMuted
      self.createdAtVisibleGeneration = createdAtVisibleGeneration
    }

    deinit {
      if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
      if let accessLogObserver { NotificationCenter.default.removeObserver(accessLogObserver) }
      if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
    }
  }

  private let onState: StateCallback
  private let onReleased: ReleasedCallback
  private let onPosition: PositionCallback
  private let onMetrics: MetricsCallback
  private let onVideoSize: VideoSizeCallback

  private let makePlayer: () -> AVQueuePlayer
  private let loadLoopAsset: LoopAssetLoader
  private let setAudioSessionActive: (Bool, AVAudioSession.SetActiveOptions) throws -> Void
  private let applicationState: () -> UIApplication.State
  private var isBackgrounded = false
  private let registry = FeedSourceRegistry()
  private let resourceLoaderQueue = DispatchQueue(label: "native_feed_player.loader.delegate")
  private let resourceLoader: CachingResourceLoader
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
  private var manageAudioSession: Bool = true
  /// Whether the plugin activated the audio session; re-activation is skipped
  /// until the session is reset so policy updates do not block the main thread.
  private var audioSessionActivated = false

  /// Controllers paused by backgrounding, to be resumed on return.
  private var autoPausedControllerIds = Set<Int>()
  private var pendingRateByController: [Int: Float] = [:]
  private var backgroundObserver: NSObjectProtocol?
  private var foregroundObserver: NSObjectProtocol?
  private var visibleGeneration: Int = 0
  private var preloadGeneration: Int = 0
  private var positionTimer: Timer?

  /// Preload-window multiplier reduced under rebuffer or memory pressure.
  private var adaptivePreloadPolicy = AdaptivePreloadPolicy()

  /// Maximum combined active and pooled player count.
  private var maxTotalPlayers: Int = 6

  private func totalLivePlayers() -> Int {
    controllers.count + pooledPlayers.count
  }

  private func assertMainQueue() {
    dispatchPrecondition(condition: .onQueue(.main))
  }

  private func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  init(
    onState: @escaping StateCallback,
    onReleased: @escaping ReleasedCallback,
    onPosition: @escaping PositionCallback,
    onMetrics: @escaping MetricsCallback,
    onVideoSize: @escaping VideoSizeCallback,
    makePlayer: @escaping () -> AVQueuePlayer = { AVQueuePlayer() },
    loadLoopAsset: @escaping LoopAssetLoader = AVPlayerManager.loadLoopAssetMetadata,
    applicationState: @escaping () -> UIApplication.State = { UIApplication.shared.applicationState },
    setAudioSessionActive: @escaping (Bool, AVAudioSession.SetActiveOptions) throws -> Void = {
      try AVAudioSession.sharedInstance().setActive($0, options: $1)
    }
  ) {
    self.makePlayer = makePlayer
    self.loadLoopAsset = loadLoopAsset
    self.applicationState = applicationState
    self.setAudioSessionActive = setAudioSessionActive
    self.resourceLoader = CachingResourceLoader(queue: resourceLoaderQueue)
    self.onState = onState
    self.onReleased = onReleased
    self.onPosition = onPosition
    self.onMetrics = onMetrics
    self.onVideoSize = onVideoSize
    resourceLoader.onFailure = { [weak self] identity, error in
      self?.onMain { [weak self] in
        self?.handleResourceFailure(identity: identity, error: error)
      }
    }
    assertMainQueue()
    observeAppLifecycle()
  }

  deinit {
    // Timer invalidation must happen on the timer's runloop; deinit can run
    // on any thread. NotificationCenter removal is thread-safe, so observers
    // are always removed.
    let timer = positionTimer
    if Thread.isMainThread {
      timer?.invalidate()
    } else {
      DispatchQueue.main.async {
        timer?.invalidate()
      }
    }
    stopObservingAppLifecycle()
    resourceLoader.shutdown()
    for managed in controllers.values {
      managed.player.pause()
    }
    deactivateAudioSession()
  }

  func initialize(config: FeedPlayerConfigMessage) {
    assertMainQueue()
    observeAppLifecycle()
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

  func setSources(_ sources: [RegisteredSource]) throws {
    assertMainQueue()
    try validateSources(sources)
    registry.replaceAll(sources)
    releaseOrphanedPreparedItems()
    releaseOrphanedControllers()
    enforceVisibleWindowEviction()
    schedulePreloadWindow()
  }

  private func releaseOrphanedControllers() {
    let orphanedControllerIds = controllers.values
      .filter { managed in
        guard let source = registry.source(id: managed.sourceId) else {
          return true
        }
        return source.playbackIdentity != managed.playbackIdentity
      }
      .map(\.id)
    for controllerId in orphanedControllerIds {
      disposeControllerInternal(
        controllerId: controllerId,
        reason: .disposed,
        shouldReschedule: false
      )
    }
  }

  func appendSources(_ sources: [RegisteredSource]) throws {
    assertMainQueue()
    try validateSources(sources)
    registry.append(sources)
    releaseOrphanedPreparedItems()
    releaseOrphanedControllers()
    schedulePreloadWindow()
  }

  func removeSources(_ sourceIds: [String]) {
    assertMainQueue()
    registry.remove(ids: sourceIds)
    for sourceId in sourceIds {
      discardPreparedItem(sourceId: sourceId)
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
    assertMainQueue()
    guard let source = registry.source(id: sourceId) else {
      throw PlaybackSetupError(
        code: "source_not_found",
        message: "No registered source with id=\(sourceId). Call setSources first."
      )
    }
    try validateSources([source])

    if controllers[controllerId] != nil {
      disposeControllerInternal(controllerId: controllerId, reason: .disposed, shouldReschedule: false)
    }
    evictToActiveLimit(protectedSourceId: sourceId)

    guard let item = takePreparedItem(for: source) ?? makePlayerItem(for: source) else {
      throw PlaybackSetupError(
        code: "invalid_url",
        message: "Invalid URI for source \(sourceId): \(source.uri)"
      )
    }
    let player = obtainReusablePlayer()
    player.removeAllItems()
    let isResourceLoaded = (item.asset as? AVURLAsset).flatMap {
      CachingResourceLoader.identity(from: $0.url)
    } != nil
    player.automaticallyWaitsToMinimizeStalling = !isResourceLoaded
    player.volume = muted ? 0 : volume
    // A recycled player must not inherit the previous controller's mute.
    player.isMuted = muted

    let managed = ManagedController(
      id: controllerId,
      sourceId: sourceId,
      requestIdentity: source.cacheIdentity,
      resourceIdentity: source.resourceIdentity,
      playbackIdentity: source.playbackIdentity,
      sourceKind: source.kind,
      player: player,
      originalItem: item,
      looping: looping,
      targetVolume: volume,
      isMuted: muted,
      createdAtVisibleGeneration: visibleGeneration
    )

    managed.wantsToPlay = autoPlay
    controllers[controllerId] = managed
    creationOrder.append(controllerId)
    metricsByController[controllerId] = PlaybackMetrics()
    observeCurrentItem(to: managed)
    if looping {
      // AVPlayerLooper schedules gapless repeats.
      onState(controllerId, .preparing, nil)
      configureLoop(managed, position: .invalid)
    } else {
      player.insert(item, after: nil)
      player.actionAtItemEnd = .pause
    }
    emitMetrics(controllerId)
    if let renderView = attachedRenderViews[controllerId] {
      bindRenderView(renderView, to: managed)
    }
    startPositionTimerIfNeeded()

    applyPlaybackIntent(managed)

    // Apply eviction after controller registration.
    enforceVisibleWindowEviction()
    enforceTotalPlayerBudget(protectedControllerId: controllerId)
    schedulePreloadWindow()
  }

  func play(controllerId: Int) {
    assertMainQueue()
    autoPausedControllerIds.remove(controllerId)
    guard let managed = controllers[controllerId] else {
      return
    }
    managed.wantsToPlay = true
    applyPlaybackIntent(managed)
  }

  func pause(controllerId: Int) {
    assertMainQueue()
    autoPausedControllerIds.remove(controllerId)
    guard let managed = controllers[controllerId] else {
      return
    }
    managed.wantsToPlay = false
    applyPlaybackIntent(managed)
  }

  // MARK: - Controls

  func setVolume(controllerId: Int, value: Double) {
    assertMainQueue()
    guard let managed = controllers[controllerId] else {
      return
    }
    managed.targetVolume = min(max(Float(value), 0), 1)
    managed.player.volume = managed.isMuted ? 0 : managed.targetVolume
  }

  func setMuted(controllerId: Int, value: Bool) {
    assertMainQueue()
    guard let managed = controllers[controllerId] else {
      return
    }
    managed.isMuted = value
    managed.player.volume = value ? 0 : managed.targetVolume
  }

  func setPlaybackSpeed(controllerId: Int, speed: Double) {
    assertMainQueue()
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
    assertMainQueue()
    guard let managed = controllers[controllerId], managed.looping != looping else {
      return
    }
    let position = managed.pendingSeek ?? managed.seekTarget ?? managed.player.currentTime()
    managed.looping = looping
    configureLoop(managed, position: position)
  }

  private func applyPlaybackIntent(_ managed: ManagedController) {
    guard controllers[managed.id] === managed else { return }
    if isBackgrounded && managed.wantsToPlay {
      autoPausedControllerIds.insert(managed.id)
    } else {
      autoPausedControllerIds.remove(managed.id)
    }
    if managed.wantsToPlay && !isBackgrounded && !managed.isConfiguringLoop
      && !managed.didReportPlaybackError {
      if managed.player.automaticallyWaitsToMinimizeStalling {
        managed.player.play()
      } else {
        managed.playbackRecoveryPending = true
        resumeCustomPlaybackIfReady(managed)
      }
    } else {
      managed.playbackRecoveryPending = false
      managed.isBuffering = false
      managed.player.pause()
    }
  }

  static func hasResumeBuffer(position: CMTime, duration: CMTime, ranges: [CMTimeRange]) -> Bool {
    guard position.isNumeric, position.seconds.isFinite, position.seconds >= 0 else { return false }
    let time = position.seconds
    let end = duration.isNumeric && duration.seconds.isFinite ? duration.seconds : .infinity
    guard time < end else { return false }
    return ranges.contains { range in
      let start = range.start.seconds
      let bufferedEnd = CMTimeRangeGetEnd(range).seconds
      return start.isFinite && bufferedEnd.isFinite && start <= time && bufferedEnd > time
        && (bufferedEnd - time >= 0.25 || bufferedEnd >= end)
    }
  }

  private func resumeCustomPlaybackIfReady(_ managed: ManagedController) {
    guard controllers[managed.id] === managed,
      !managed.player.automaticallyWaitsToMinimizeStalling,
      managed.playbackRecoveryPending, managed.wantsToPlay,
      managed.observerSetupDepth == 0, !managed.isSeeking,
      !isBackgrounded, !managed.isConfiguringLoop, !managed.didReportPlaybackError,
      let item = managed.player.currentItem, item.status == .readyToPlay
    else { return }
    if managed.player.timeControlStatus == .playing {
      if !item.isPlaybackBufferEmpty {
        managed.playbackRecoveryPending = false
        managed.isBuffering = false
      }
      return
    }
    guard !item.isPlaybackBufferEmpty,
      Self.hasResumeBuffer(
        position: managed.player.currentTime(), duration: item.duration,
        ranges: item.loadedTimeRanges.map(\.timeRangeValue)
      )
    else {
      noteCustomBuffering(managed)
      return
    }
    managed.playbackRecoveryPending = false
    managed.player.playImmediately(atRate: pendingRateByController[managed.id] ?? 1)
  }

  private func noteCustomBuffering(_ managed: ManagedController) {
    guard controllers[managed.id] === managed,
      !managed.player.automaticallyWaitsToMinimizeStalling,
      managed.wantsToPlay, !isBackgrounded, !managed.isConfiguringLoop, !managed.isSeeking,
      !managed.didReportPlaybackError, let item = managed.player.currentItem
    else { return }
    let position = managed.player.currentTime().seconds
    let duration = item.duration.seconds
    guard !duration.isFinite || duration <= 0 || !position.isFinite || position < duration else { return }
    managed.playbackRecoveryPending = true
    guard !managed.isBuffering else { return }
    managed.isBuffering = true
    if managed.hasStartedPlayback, var metrics = metricsByController[managed.id], metrics.hasBeenReady {
      metrics.rebufferCount += 1
      metricsByController[managed.id] = metrics
      noteRebuffer()
      emitMetrics(managed.id)
    }
    onState(managed.id, .buffering, nil)
  }

  private func clearBufferObservers(_ managed: ManagedController) {
    managed.bufferEmptyObservation?.invalidate()
    managed.bufferEmptyObservation = nil
    managed.loadedRangesObservation?.invalidate()
    managed.loadedRangesObservation = nil
    if let observer = managed.stalledObserver {
      NotificationCenter.default.removeObserver(observer)
      managed.stalledObserver = nil
    }
  }

  private func observeBuffering(_ managed: ManagedController, item: AVPlayerItem) {
    clearBufferObservers(managed)
    guard !managed.player.automaticallyWaitsToMinimizeStalling else { return }
    let update: () -> Void = { [weak self, weak managed, weak item] in
      self?.onMain { [weak self, weak managed, weak item] in
        guard let self, let managed, let item,
          self.controllers[managed.id] === managed, managed.player.currentItem === item
        else { return }
        if item.isPlaybackBufferEmpty, managed.player.timeControlStatus != .playing {
          self.noteCustomBuffering(managed)
        }
        self.resumeCustomPlaybackIfReady(managed)
      }
    }
    managed.bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { _, _ in update() }
    managed.loadedRangesObservation = item.observe(\.loadedTimeRanges, options: [.new]) { _, _ in update() }
    managed.stalledObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
    ) { [weak self, weak managed, weak item] _ in
      guard let self, let managed, let item, managed.player.currentItem === item else { return }
      self.noteCustomBuffering(managed)
      self.resumeCustomPlaybackIfReady(managed)
    }
  }

  static func loadLoopAssetMetadata(
    _ asset: AVAsset,
    completion: @escaping (Result<CMTime, Error>) -> Void
  ) {
    let keys = ["duration", "playable", "tracks"]
    asset.loadValuesAsynchronously(forKeys: keys) {
      for key in keys {
        var error: NSError?
        guard asset.statusOfValue(forKey: key, error: &error) == .loaded else {
          completion(.failure((error as Error?) ?? PlaybackSetupError(
            code: "media_malformed", message: "Unable to load looping asset \(key)."
          )))
          return
        }
      }
      guard asset.isPlayable else {
        completion(.failure(PlaybackSetupError(
          code: "media_malformed", message: "The looping asset is not playable."
        )))
        return
      }
      completion(.success(asset.duration))
    }
  }

  private func configureLoop(_ managed: ManagedController, position: CMTime) {
    guard controllers[managed.id] === managed, !managed.didReportPlaybackError else { return }
    managed.loopOperationGeneration += 1
    let generation = managed.loopOperationGeneration
    managed.seekOperationGeneration += 1
    managed.isSeeking = false
    managed.seekTarget = position.isNumeric ? position : nil
    managed.isConfiguringLoop = true
    managed.player.pause()
    managed.looperStatusObservation?.invalidate()
    managed.looperStatusObservation = nil
    managed.looper?.disableLooping()
    managed.looper = nil
    managed.player.removeAllItems()
    guard managed.looping else {
      managed.player.insert(managed.originalItem, after: nil)
      managed.player.actionAtItemEnd = .pause
      finishLoopConfiguration(managed, generation: generation, position: position)
      return
    }
    loadLoopAsset(managed.originalItem.asset) { [weak self, weak managed] result in
      DispatchQueue.main.async {
        guard let self, let managed,
          self.controllers[managed.id] === managed,
          managed.loopOperationGeneration == generation,
          managed.looping, !managed.didReportPlaybackError
        else { return }
        do {
          let duration = try result.get()
          guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw PlaybackSetupError(
              code: "media_malformed", message: "Looping requires a finite, positive asset duration."
            )
          }
          managed.looper = AVPlayerLooper(
            player: managed.player, templateItem: managed.originalItem,
            timeRange: CMTimeRange(start: .zero, duration: duration)
          )
          self.attachLooperObserver(to: managed)
          self.finishLoopConfiguration(managed, generation: generation, position: position)
        } catch {
          managed.isConfiguringLoop = false
          let mapped: PlaybackErrorMessage
          if let setup = error as? PlaybackSetupError {
            mapped = PlaybackErrorMessage(
              code: setup.code, message: setup.message, isRecoverable: false, platformCode: nil
            )
          } else {
            mapped = PlaybackErrorMapper.map(error, sourceId: managed.sourceId)
          }
          self.reportPlaybackFailure(managed, mapped)
        }
      }
    }
  }

  private func finishLoopConfiguration(
    _ managed: ManagedController, generation: Int, position: CMTime
  ) {
    guard controllers[managed.id] === managed,
      managed.loopOperationGeneration == generation, !managed.didReportPlaybackError
    else { return }
    let target = managed.pendingSeek ?? position
    managed.pendingSeek = nil
    guard target.isNumeric, target.seconds >= 0 else {
      managed.seekTarget = nil
      managed.isConfiguringLoop = false
      applyPlaybackIntent(managed)
      return
    }
    managed.seekTarget = target
    managed.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self, weak managed] finished in
      DispatchQueue.main.async {
        guard let self, let managed,
          self.controllers[managed.id] === managed,
          managed.loopOperationGeneration == generation, !managed.didReportPlaybackError
        else { return }
        if managed.pendingSeek != nil {
          self.finishLoopConfiguration(managed, generation: generation, position: .invalid)
        } else {
          managed.seekTarget = nil
          managed.isConfiguringLoop = false
          if finished {
            self.applyPlaybackIntent(managed)
          } else {
            managed.playbackRecoveryPending = false
          }
        }
      }
    }
  }

  /// Applies audio policy to current and future players.
  func applyAudioPolicy(_ policy: AudioPolicyMessage) {
    assertMainQueue()
    muted = policy.muted
    volume = min(max(Float(policy.volume), 0), 1)
    handleAudioFocus = policy.handleAudioFocus && !policy.muted
    if manageAudioSession && !policy.manageAudioSession {
      deactivateAudioSession()
    }
    manageAudioSession = policy.manageAudioSession

    configureAudioSession()
    for managed in controllers.values {
      managed.targetVolume = volume
      managed.isMuted = muted
      managed.player.volume = muted ? 0 : volume
    }
  }

  private func configureAudioSession() {
    // The host app owns the session when it opts out; never touch it.
    guard manageAudioSession else {
      return
    }
    let session = AVAudioSession.sharedInstance()
    do {
      // While manageAudioSession is on the plugin owns category, mode, and
      // options, so compare against exactly what it would set. AVFoundation
      // reports back the options it was given, so the comparison is stable
      // and skips redundant setCategory calls.
      if muted {
        // Preserve external audio while muted. .moviePlayback is only valid
        // with .playback, so the ambient path uses the default mode.
        if session.category != .ambient || session.mode != .default
          || session.categoryOptions != [.mixWithOthers]
        {
          try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        }
      } else if handleAudioFocus {
        if session.category != .playback || session.mode != .moviePlayback
          || !session.categoryOptions.isEmpty
        {
          try session.setCategory(.playback, mode: .moviePlayback)
        }
      } else {
        if session.category != .playback || session.mode != .moviePlayback
          || session.categoryOptions != [.mixWithOthers]
        {
          try session.setCategory(
            .playback,
            mode: .moviePlayback,
            options: [.mixWithOthers]
          )
        }
      }
      if !audioSessionActivated {
        try setAudioSessionActive(true, [])
        audioSessionActivated = true
      }
    } catch {
      // Audio-session failure does not stop playback.
    }
  }

  private func deactivateAudioSession() {
    guard manageAudioSession, audioSessionActivated else { return }
    audioSessionActivated = false
    try? setAudioSessionActive(false, [.notifyOthersOnDeactivation])
  }

  // MARK: - App lifecycle

  private func observeAppLifecycle() {
    assertMainQueue()
    guard backgroundObserver == nil, foregroundObserver == nil else {
      return
    }
    isBackgrounded = applicationState() == .background
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

  private func stopObservingAppLifecycle() {
    let center = NotificationCenter.default
    if let backgroundObserver {
      center.removeObserver(backgroundObserver)
      self.backgroundObserver = nil
    }
    if let foregroundObserver {
      center.removeObserver(foregroundObserver)
      self.foregroundObserver = nil
    }
  }

  /// Pauses active players until the app returns to the foreground.
  private func onAppBackgrounded() {
    assertMainQueue()
    isBackgrounded = true
    for managed in controllers.values {
      applyPlaybackIntent(managed)
    }
  }

  private func onAppForegrounded() {
    assertMainQueue()
    isBackgrounded = false
    for managed in controllers.values {
      applyPlaybackIntent(managed)
    }
    autoPausedControllerIds.removeAll()
  }

  func seekTo(controllerId: Int, positionMs: Int64) {
    assertMainQueue()
    guard let managed = controllers[controllerId] else {
      return
    }
    let time = CMTime(value: max(Int64(0), positionMs), timescale: 1000)
    if managed.isConfiguringLoop {
      managed.pendingSeek = time
      return
    }
    managed.seekOperationGeneration += 1
    let generation = managed.seekOperationGeneration
    managed.isSeeking = true
    managed.seekTarget = time
    managed.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self, weak managed] finished in
      self?.onMain { [weak self, weak managed] in
        guard let self, let managed,
          self.controllers[managed.id] === managed,
          managed.seekOperationGeneration == generation, !managed.didReportPlaybackError
        else { return }
        managed.isSeeking = false
        managed.seekTarget = nil
        if finished, !managed.player.automaticallyWaitsToMinimizeStalling {
          self.applyPlaybackIntent(managed)
        } else if !finished {
          managed.playbackRecoveryPending = false
        }
      }
    }
  }

  func disposeController(controllerId: Int) {
    assertMainQueue()
    disposeControllerInternal(
      controllerId: controllerId,
      reason: .disposed,
      shouldReschedule: true
    )
  }

  func setVisibleSource(_ sourceId: String) {
    assertMainQueue()
    // Unknown IDs must not advance the generation and accidentally make newly
    // created controllers eligible for eviction.
    guard registry.setVisible(sourceId) else {
      return
    }
    visibleGeneration += 1
    enforceVisibleWindowEviction()
    enforceTotalPlayerBudget()
    schedulePreloadWindow()
  }

  func attach(controllerId: Int, renderView: NativeVideoRenderView) {
    assertMainQueue()
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
    assertMainQueue()
    return controllers[controllerId]?.player
  }

  /// Routes texture-mode first pixels through the same idempotent metric path
  /// used by platform-view display readiness.
  func markTextureFirstFrame(controllerId: Int) {
    assertMainQueue()
    markFirstFrame(controllerId)
  }

  func handleResourceFailure(identity: String, error: Error) {
    assertMainQueue()
    for managed in controllers.values where managed.resourceIdentity == identity {
      reportPlaybackFailure(
        managed,
        PlaybackErrorMapper.map(error, sourceId: managed.sourceId)
      )
    }
  }

  func detach(controllerId: Int, renderView expected: NativeVideoRenderView? = nil) {
    assertMainQueue()
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
    assertMainQueue()
    preloadGeneration += 1
    adaptivePreloadPolicy.noteMemoryPressure(at: AVPlayerManager.currentUptimeMs())
    discardAllPreparedItems()
    drainPooledPlayers(keep: 0)
    enforceVisibleWindowEviction(forceAggressive: true)
  }

  /// Reduces the preload window after repeated stalls.
  private func noteRebuffer() {
    if adaptivePreloadPolicy.noteRebuffer(at: AVPlayerManager.currentUptimeMs()) {
      schedulePreloadWindow()
    }
  }

  /// Restores the preload window only after sustained playback time.
  private func noteSteadyPlayback() {
    if adaptivePreloadPolicy.notePlaybackProgress(at: AVPlayerManager.currentUptimeMs()) {
      schedulePreloadWindow()
    }
  }

  func disposeAll() {
    assertMainQueue()
    resetSession(reason: .engineDetached)
    stopObservingAppLifecycle()
  }

  private func resetSession(reason: ReleaseReasonMessage) {
    assertMainQueue()
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
    discardAllPreparedItems()
    metricsByController.removeAll()
    creationOrder.removeAll()
    autoPausedControllerIds.removeAll()
    pendingRateByController.removeAll()
    visibleGeneration = 0
    adaptivePreloadPolicy.reset()
    drainPooledPlayers(keep: 0)
    positionTimer?.invalidate()
    positionTimer = nil
    // A fresh session must re-activate the audio session.
    deactivateAudioSession()
  }

  // MARK: - Prebuffering

  private func discardPreparedItem(sourceId: String) {
    guard let prepared = preparedItems.removeValue(forKey: sourceId) else {
      return
    }
    prepared.item.asset.cancelLoading()
    let identity = prepared.requestIdentity
    let stillUsed = preparedItems.values.contains { $0.requestIdentity == identity }
      || controllers.values.contains { $0.requestIdentity == identity }
    if !stillUsed {
      resourceLoader.cancel(identities: [identity], completion: {})
    }
  }

  private func discardAllPreparedItems() {
    for sourceId in Array(preparedItems.keys) {
      discardPreparedItem(sourceId: sourceId)
    }
  }

  /// Prepares items in the current preload window.
  private func schedulePreloadWindow() {
    preloadGeneration += 1
    let generation = preloadGeneration
    let window = registry.preloadWindow(
      ahead: preloadAhead,
      behind: preloadBehind,
      scale: adaptivePreloadPolicy.scale
    )
    let windowIds = Set(window.map(\.id))

    for sourceId in Array(preparedItems.keys) where !windowIds.contains(sourceId) {
      discardPreparedItem(sourceId: sourceId)
    }

    var availableSlots = max(0, maxConcurrentPreloads - preparedItems.count)
    for source in window {
      if availableSlots == 0 {
        break
      }
      if controllers.values.contains(where: { $0.sourceId == source.id }) {
        continue
      }
      if let existing = preparedItems[source.id] {
        if existing.playbackIdentity == source.playbackIdentity {
          continue
        }
        discardPreparedItem(sourceId: source.id)
      }
      availableSlots -= 1
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
        guard let item = self.makePlayerItem(for: fresh) else {
          return
        }
        // Scale buffering by viewport distance.
        let distance = self.registry.distanceFromVisible(id: fresh.id) ?? self.preloadAhead
        item.preferredForwardBufferDuration = distance <= 1 ? 4 : 2
        self.preparedItems[fresh.id] = PreparedItem(
          sourceId: fresh.id,
          requestIdentity: fresh.cacheIdentity,
          playbackIdentity: fresh.playbackIdentity,
          sourceKind: fresh.kind,
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
    guard let prepared = preparedItems[source.id],
      prepared.playbackIdentity == source.playbackIdentity
    else {
      discardPreparedItem(sourceId: source.id)
      return nil
    }
    preparedItems.removeValue(forKey: source.id)
    return prepared.item
  }

  private func validateSources(_ sources: [RegisteredSource]) throws {
    if let source = sources.first(where: { !$0.headers.isEmpty && isHLS($0) }) {
      throw PlaybackSetupError(
        code: "unsupported_hls_headers",
        message: "iOS HLS sources with custom headers are unsupported. Use signed URLs or cookies for source \(source.id)."
      )
    }
    if let source = sources.first(where: { !isPlayableURL($0.uri) }) {
      throw PlaybackSetupError(
        code: "invalid_url",
        message: "Invalid URI for source \(source.id): \(source.uri)"
      )
    }
  }

  /// Rejects URIs that cannot address media: no scheme, or an HTTP(S) URL
  /// without a host. File and custom-scheme URLs only need to parse.
  private func isPlayableURL(_ uri: String) -> Bool {
    guard let url = URL(string: uri), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
      return false
    }
    if scheme == "http" || scheme == "https" {
      return url.host?.isEmpty == false
    }
    return true
  }

  private func isHLS(_ source: RegisteredSource) -> Bool {
    switch source.kind {
    case .hls:
      return true
    case .progressive:
      return false
    case .auto:
      return source.uri.lowercased().contains(".m3u8")
    }
  }

  /// Creates a cached progressive item or a network-backed HLS item.
  /// Returns nil only when the URI cannot be parsed; registration validates
  /// URLs first, so nil here means the source was mutated after validation.
  private func makePlayerItem(for source: RegisteredSource) -> AVPlayerItem? {
    guard let url = URL(string: source.uri) else {
      return nil
    }

    let asset: AVURLAsset
    if (shouldCache(source) || !source.headers.isEmpty) && !isHLS(source),
      let cachedAsset = resourceLoader.prepareAsset(
        for: source.uri,
        headers: source.headers,
        cacheKey: source.cacheKey
      )
    {
      asset = cachedAsset
    } else {
      asset = AVURLAsset(url: url)
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

  func clearMediaCache(completion: @escaping () -> Void) {
    assertMainQueue()
    resourceLoader.cancelAll {
      MediaDiskCache.shared.evictAll(completion: completion)
    }
  }

  /// Evicts the given sources, or everything when `sourceIds` is empty.
  func evictCachedMedia(_ sourceIds: [String], completion: @escaping () -> Void) {
    assertMainQueue()
    guard !sourceIds.isEmpty else {
      resourceLoader.cancelAll {
        MediaDiskCache.shared.evictAll(completion: completion)
      }
      return
    }
    let identities = Set(sourceIds.compactMap { registry.source(id: $0)?.cacheIdentity })
    resourceLoader.cancel(identities: identities) {
      MediaDiskCache.shared.evict(identities: identities, completion: completion)
    }
  }

  func cacheStatus(sourceId: String, completion: @escaping (CacheStatusMessage) -> Void) {
    assertMainQueue()
    guard let identity = registry.source(id: sourceId)?.cacheIdentity else {
      completion(
        CacheStatusMessage(
          sourceId: sourceId,
          cachedBytes: 0,
          totalBytes: 0,
          isComplete: false
        )
      )
      return
    }
    MediaDiskCache.shared.cachedBytes(forIdentity: identity) { bytes in
      // Whole-file cache entries are complete.
      completion(
        CacheStatusMessage(
          sourceId: sourceId,
          cachedBytes: bytes,
          totalBytes: bytes,
          isComplete: bytes > 0
        )
      )
    }
  }

  func cacheUsageBytes(completion: @escaping (Int64) -> Void) {
    assertMainQueue()
    MediaDiskCache.shared.usageBytes(completion: completion)
  }

  private func releaseOrphanedPreparedItems() {
    for sourceId in Array(preparedItems.keys) {
      guard let source = registry.source(id: sourceId), let prepared = preparedItems[sourceId]
      else {
        discardPreparedItem(sourceId: sourceId)
        continue
      }
      if prepared.playbackIdentity != source.playbackIdentity {
        discardPreparedItem(sourceId: sourceId)
      }
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
    if let fallback = eligible.first {
      return fallback
    }
    // Every live controller plays the protected source; evict the oldest one
    // so repeated createController calls cannot exceed the active budget.
    return creationOrder.first
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
    managed.loopOperationGeneration += 1
    managed.seekOperationGeneration += 1
    managed.isSeeking = false
    managed.seekTarget = nil
    managed.originalItem.asset.cancelLoading()
    managed.currentItemObservation?.invalidate()
    managed.observedItem = nil
    clearBufferObservers(managed)
    managed.itemStatusObservation?.invalidate()
    managed.playerStatusObservation?.invalidate()
    managed.timeControlObservation?.invalidate()
    managed.looperStatusObservation?.invalidate()
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
    ) { [weak self, weak managed] layer, _ in
      guard layer.isReadyForDisplay, let managed else {
        return
      }
      self?.onMain { [weak self, weak managed] in
        guard let self, let managed, self.controllers[managed.id] === managed else {
          return
        }
        self.markFirstFrame(managed.id)
      }
    }
  }

  private func markFirstFrame(_ controllerId: Int) {
    assertMainQueue()
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

  private func reportPlaybackFailure(
    _ managed: ManagedController,
    _ error: PlaybackErrorMessage
  ) {
    assertMainQueue()
    guard controllers[managed.id] === managed, !managed.didReportPlaybackError else {
      return
    }
    managed.didReportPlaybackError = true
    managed.wantsToPlay = false
    managed.seekOperationGeneration += 1
    managed.isSeeking = false
    managed.seekTarget = nil
    managed.loopOperationGeneration += 1
    managed.isConfiguringLoop = false
    applyPlaybackIntent(managed)
    onState(managed.id, .error, error)
  }

  private func attachLooperObserver(to managed: ManagedController) {
    managed.looperStatusObservation?.invalidate()
    guard let looper = managed.looper else {
      managed.looperStatusObservation = nil
      return
    }
    managed.looperStatusObservation = looper.observe(
      \.status,
      options: [.new, .initial]
    ) { [weak self, weak managed] looper, _ in
      guard looper.status == .failed, let managed else {
        return
      }
      self?.onMain { [weak self, weak managed] in
        guard let self, let managed else {
          return
        }
        self.reportPlaybackFailure(
          managed,
          PlaybackErrorMapper.map(looper.error, sourceId: managed.sourceId)
        )
      }
    }
  }

  private func observeCurrentItem(to managed: ManagedController) {
    managed.droppedFrames.track(item: managed.originalItem)
    managed.accessLogObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemNewAccessLogEntry, object: nil, queue: .main
    ) { [weak self, weak managed] notification in
      guard let self, let managed, self.controllers[managed.id] === managed,
        let item = notification.object as? AVPlayerItem,
        managed.droppedFrames.contains(item: item)
      else { return }
      self.updateDroppedFrames(controllerId: managed.id, item: item)
    }
    managed.currentItemObservation = managed.player.observe(\.currentItem, options: [.old, .new]) {
      [weak self, weak managed] player, change in
      let item = change.newValue ?? player.currentItem
      let previousItem = change.oldValue ?? nil
      self?.onMain { [weak self, weak managed] in
        guard let self, let managed, self.controllers[managed.id] === managed else { return }
        if let previousItem { managed.droppedFrames.track(item: previousItem) }
        self.updateDroppedFrames(controllerId: managed.id, item: previousItem)
        guard managed.player.currentItem === item else { return }
        self.updateDroppedFrames(controllerId: managed.id, item: managed.observedItem)
        managed.observedItem = item
        if let item {
          managed.droppedFrames.track(item: item)
          self.attachObservers(to: managed, playerItem: item)
        } else {
          self.clearBufferObservers(managed)
          managed.itemStatusObservation?.invalidate()
          managed.presentationSizeObservation?.invalidate()
          if let observer = managed.endObserver {
            NotificationCenter.default.removeObserver(observer)
            managed.endObserver = nil
          }
        }
      }
    }
  }

  private func attachObservers(to managed: ManagedController, playerItem: AVPlayerItem) {
    assertMainQueue()
    managed.observerSetupDepth += 1
    defer {
      managed.observerSetupDepth -= 1
      resumeCustomPlaybackIfReady(managed)
    }
    observeBuffering(managed, item: playerItem)
    if let endObserver = managed.endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      managed.endObserver = nil
    }
    managed.itemStatusObservation?.invalidate()
    managed.playerStatusObservation?.invalidate()
    managed.timeControlObservation?.invalidate()
    managed.presentationSizeObservation?.invalidate()
    managed.playerStatusObservation = managed.player.observe(
      \.status,
      options: [.new, .initial]
    ) { [weak self, weak managed] player, _ in
      guard player.status == .failed, let managed else {
        return
      }
      self?.onMain { [weak self, weak managed] in
        guard let self, let managed else {
          return
        }
        self.reportPlaybackFailure(
          managed,
          PlaybackErrorMapper.map(player.error, sourceId: managed.sourceId)
        )
      }
    }
    managed.itemStatusObservation = playerItem.observe(
      \.status,
      options: [.new, .initial]
    ) { [weak self, weak managed] item, _ in
      self?.onMain { [weak self, weak managed] in
        guard let self,
          let managed,
          self.controllers[managed.id] === managed,
          managed.player.currentItem === item
        else {
          return
        }
        if item.status == .failed {
          self.reportPlaybackFailure(
            managed,
            PlaybackErrorMapper.map(item.error, sourceId: managed.sourceId)
          )
          return
        }
        guard !managed.didReportPlaybackError else {
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
          if !managed.didEmitReady {
            managed.didEmitReady = true
            self.onState(managed.id, .ready, nil)
          }
          self.resumeCustomPlaybackIfReady(managed)
        case .unknown:
          self.onState(managed.id, .preparing, nil)
        case .failed:
          break
        @unknown default:
          self.reportPlaybackFailure(
            managed,
            PlaybackErrorMapper.unknown(message: "Unrecognised AVPlayerItem status")
          )
        }
      }
    }

    // No `.initial`: the item-status observation owns the initial preparing
    // event, and a fresh player's paused state would otherwise emit a spurious
    // idle before the item is ready.
    managed.timeControlObservation = managed.player.observe(
      \.timeControlStatus,
      options: [.new]
    ) { [weak self, weak managed] player, _ in
      self?.onMain { [weak self, weak managed] in
        guard let self, let managed, self.controllers[managed.id] === managed else {
          return
        }
        if let error = player.error {
          self.reportPlaybackFailure(
            managed,
            PlaybackErrorMapper.map(error, sourceId: managed.sourceId)
          )
          return
        }
        if let item = player.currentItem, item.status == .failed {
          self.reportPlaybackFailure(
            managed,
            PlaybackErrorMapper.map(item.error, sourceId: managed.sourceId)
          )
          return
        }
        guard !managed.didReportPlaybackError, !managed.isConfiguringLoop else {
          return
        }
        switch player.timeControlStatus {
        case .paused:
          if !player.automaticallyWaitsToMinimizeStalling,
            managed.wantsToPlay, !self.isBackgrounded,
            managed.playbackRecoveryPending || player.currentItem?.isPlaybackBufferEmpty == true {
            self.noteCustomBuffering(managed)
            self.resumeCustomPlaybackIfReady(managed)
            return
          }
          let ready = player.currentItem?.status == .readyToPlay
          self.onState(managed.id, ready ? .paused : .idle, nil)
        case .waitingToPlayAtSpecifiedRate:
          if !player.automaticallyWaitsToMinimizeStalling {
            self.noteCustomBuffering(managed)
            self.resumeCustomPlaybackIfReady(managed)
            return
          }
          if var metrics = self.metricsByController[managed.id], metrics.hasBeenReady {
            metrics.rebufferCount += 1
            self.metricsByController[managed.id] = metrics
            self.noteRebuffer()
            self.emitMetrics(managed.id)
          }
          self.onState(managed.id, .buffering, nil)
        case .playing:
          managed.hasStartedPlayback = true
          managed.playbackRecoveryPending = false
          managed.isBuffering = false
          if var metrics = self.metricsByController[managed.id] {
            metrics.hasBeenReady = true
            self.metricsByController[managed.id] = metrics
          }
          if !managed.didEmitReady {
            managed.didEmitReady = true
            self.onState(managed.id, .ready, nil)
          }
          // Apply deferred playback speed after playback starts.
          if let rate = self.pendingRateByController[managed.id], player.rate != rate {
            player.rate = rate
          }
          self.noteSteadyPlayback()
          self.onState(managed.id, .playing, nil)
        @unknown default:
          self.reportPlaybackFailure(
            managed,
            PlaybackErrorMapper.unknown(message: "Unrecognised timeControlStatus")
          )
        }
      }
    }

    managed.presentationSizeObservation = playerItem.observe(
      \.presentationSize,
      options: [.new, .initial]
    ) { [weak self, weak managed] item, _ in
      let size = item.presentationSize
      guard size.width > 0, size.height > 0, let managed else {
        return
      }
      self?.onMain { [weak self, weak managed] in
        guard let self,
          let managed,
          self.controllers[managed.id] === managed,
          managed.player.currentItem === item
        else {
          return
        }
        // AVFoundation reports display-oriented dimensions.
        self.onVideoSize(
          VideoSizeEvent(
            controllerId: Int64(managed.id),
            width: Int64(size.width),
            height: Int64(size.height),
            rotationDegrees: 0
          )
        )
      }
    }

    // AVPlayerLooper handles item completion for looping playback.
    managed.endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self, weak managed, weak playerItem] _ in
      guard let self,
        let managed,
        self.controllers[managed.id] === managed,
        !managed.didReportPlaybackError
      else {
        return
      }
      self.updateDroppedFrames(controllerId: managed.id, item: playerItem)
      guard !managed.looping, managed.player.currentItem === playerItem else { return }
      managed.wantsToPlay = false
      self.autoPausedControllerIds.remove(managed.id)
      self.onState(managed.id, .completed, nil)
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
    assertMainQueue()
    var hasPlayingController = false
    for (controllerId, managed) in controllers {
      // Skip position updates for idle offscreen players.
      resumeCustomPlaybackIfReady(managed)
      let isRendering = attachedRenderViews[controllerId] != nil
      let isPlaying = managed.player.timeControlStatus == .playing
      hasPlayingController = hasPlayingController || isPlaying
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
    if hasPlayingController {
      noteSteadyPlayback()
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
      let managed = controllers[controllerId],
      var metrics = metricsByController[controllerId],
      let events = item.accessLog()?.events,
      !events.isEmpty
    else {
      return
    }

    let total = events.reduce(0) { partial, event in
      partial + max(0, Int(event.numberOfDroppedVideoFrames))
    }

    managed.droppedFrames.record(item: item, droppedFrames: total)
    if managed.droppedFrames.total != metrics.droppedFrames {
      metrics.droppedFrames = managed.droppedFrames.total
      metricsByController[controllerId] = metrics
      emitMetrics(controllerId)
    }
  }

  // MARK: - Player pooling

  private func obtainReusablePlayer() -> AVQueuePlayer {
    if let player = pooledPlayers.popLast() {
      return player
    }
    return makePlayer()
  }

  private func recycleOrReleasePlayer(_ player: AVQueuePlayer) {
    player.pause()
    // Reset player-global state so a recycled player cannot leak the previous
    // controller's volume or mute into the next one.
    player.volume = 1.0
    player.isMuted = false
    player.cancelPendingPrerolls()
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
