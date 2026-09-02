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
    var endObserver: NSObjectProtocol?
    var loopOperationGeneration = 0
    var playbackCommandGeneration = 0
    var didEmitReady = false
    var didReportPlaybackError = false

    init(
      id: Int,
      sourceId: String,
      requestIdentity: String,
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
      self.sourceKind = sourceKind
      self.player = player
      self.originalItem = originalItem
      self.looping = looping
      self.targetVolume = targetVolume
      self.isMuted = isMuted
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
    onVideoSize: @escaping VideoSizeCallback
  ) {
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
    let orphanedControllerIds = controllers.values
      .filter { managed in
        guard let source = registry.source(id: managed.sourceId) else {
          return true
        }
        return source.cacheIdentity != managed.requestIdentity || source.kind != managed.sourceKind
      }
      .map(\.id)
    for controllerId in orphanedControllerIds {
      disposeControllerInternal(
        controllerId: controllerId,
        reason: .disposed,
        shouldReschedule: false
      )
    }
    enforceVisibleWindowEviction()
    schedulePreloadWindow()
  }

  func appendSources(_ sources: [RegisteredSource]) throws {
    assertMainQueue()
    try validateSources(sources)
    registry.append(sources)
    schedulePreloadWindow()
  }

  func removeSources(_ sourceIds: [String]) {
    assertMainQueue()
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
    assertMainQueue()
    guard let source = registry.source(id: sourceId) else {
      throw PlaybackSetupError(
        code: "source_not_found",
        message: "No registered source with id=\(sourceId). Call setSources first."
      )
    }
    try validateSources([source])

    evictToActiveLimit(protectedSourceId: sourceId)

    guard let item = takePreparedItem(for: source) ?? makePlayerItem(for: source) else {
      throw PlaybackSetupError(
        code: "invalid_url",
        message: "Invalid URI for source \(sourceId): \(source.uri)"
      )
    }
    let player = obtainReusablePlayer()
    player.removeAllItems()
    player.automaticallyWaitsToMinimizeStalling = true
    player.volume = muted ? 0 : volume
    // A recycled player must not inherit the previous controller's mute.
    player.isMuted = muted

    let managed = ManagedController(
      id: controllerId,
      sourceId: sourceId,
      requestIdentity: source.cacheIdentity,
      sourceKind: source.kind,
      player: player,
      originalItem: item,
      looping: looping,
      targetVolume: volume,
      isMuted: muted,
      createdAtVisibleGeneration: visibleGeneration
    )

    if looping {
      // AVPlayerLooper schedules gapless repeats.
      managed.looper = AVPlayerLooper(player: player, templateItem: item)
    } else {
      player.insert(item, after: nil)
      player.actionAtItemEnd = .pause
    }

    controllers[controllerId] = managed
    creationOrder.append(controllerId)
    metricsByController[controllerId] = PlaybackMetrics()
    attachLooperObserver(to: managed)
    attachObservers(to: managed, playerItem: player.currentItem ?? item)
    emitMetrics(controllerId)
    if let renderView = attachedRenderViews[controllerId] {
      bindRenderView(renderView, to: managed)
    }
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
    assertMainQueue()
    autoPausedControllerIds.remove(controllerId)
    guard let managed = controllers[controllerId] else {
      return
    }
    managed.playbackCommandGeneration += 1
    managed.player.play()
  }

  func pause(controllerId: Int) {
    assertMainQueue()
    autoPausedControllerIds.remove(controllerId)
    guard let managed = controllers[controllerId] else {
      return
    }
    managed.playbackCommandGeneration += 1
    managed.player.pause()
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
    let player = managed.player
    let position = player.currentTime()
    let shouldResume = player.timeControlStatus == .playing || player.rate != 0
    managed.loopOperationGeneration += 1
    let operationGeneration = managed.loopOperationGeneration
    let playbackCommandGeneration = managed.playbackCommandGeneration

    managed.looperStatusObservation?.invalidate()
    managed.looperStatusObservation = nil
    managed.looper?.disableLooping()
    managed.looper = nil
    player.removeAllItems()
    managed.looping = looping
    if looping {
      managed.looper = AVPlayerLooper(player: player, templateItem: managed.originalItem)
    } else {
      player.insert(managed.originalItem, after: nil)
      player.actionAtItemEnd = .pause
    }
    attachLooperObserver(to: managed)
    attachObservers(to: managed, playerItem: player.currentItem ?? managed.originalItem)
    if position.isNumeric {
      player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) {
        [weak self, weak managed, weak player] completed in
        guard completed else {
          return
        }
        DispatchQueue.main.async {
          guard let self, let managed, let player,
            self.controllers[managed.id] === managed,
            managed.loopOperationGeneration == operationGeneration,
            managed.playbackCommandGeneration == playbackCommandGeneration,
            shouldResume
          else {
            return
          }
          player.play()
        }
      }
    } else if shouldResume {
      player.play()
    }
  }

  /// Applies audio policy to current and future players.
  func applyAudioPolicy(_ policy: AudioPolicyMessage) {
    assertMainQueue()
    muted = policy.muted
    volume = min(max(Float(policy.volume), 0), 1)
    handleAudioFocus = policy.handleAudioFocus && !policy.muted
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
        try session.setActive(true, options: [])
        audioSessionActivated = true
      }
    } catch {
      // Audio-session failure does not stop playback.
    }
  }

  // MARK: - App lifecycle

  private func observeAppLifecycle() {
    assertMainQueue()
    guard backgroundObserver == nil, foregroundObserver == nil else {
      return
    }
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
    for (controllerId, managed) in controllers
    where managed.player.timeControlStatus == .playing {
      autoPausedControllerIds.insert(controllerId)
      managed.playbackCommandGeneration += 1
      managed.player.pause()
    }
  }

  private func onAppForegrounded() {
    assertMainQueue()
    for controllerId in autoPausedControllerIds {
      guard let managed = controllers[controllerId] else {
        continue
      }
      managed.playbackCommandGeneration += 1
      managed.player.play()
    }
    autoPausedControllerIds.removeAll()
  }

  func seekTo(controllerId: Int, positionMs: Int64) {
    assertMainQueue()
    guard let player = controllers[controllerId]?.player else {
      return
    }
    let time = CMTime(value: max(Int64(0), positionMs), timescale: 1000)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
    for managed in controllers.values where managed.requestIdentity == identity {
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
    preparedItems.removeAll()
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
    preparedItems.removeAll()
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
    audioSessionActivated = false
  }

  // MARK: - Prebuffering

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
      if let existing = preparedItems[source.id] {
        if existing.requestIdentity == source.cacheIdentity && existing.sourceKind == source.kind {
          continue
        }
        preparedItems.removeValue(forKey: source.id)
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
        guard let item = self.makePlayerItem(for: fresh) else {
          return
        }
        // Scale buffering by viewport distance.
        let distance = self.registry.distanceFromVisible(id: fresh.id) ?? self.preloadAhead
        item.preferredForwardBufferDuration = distance <= 1 ? 4 : 2
        self.preparedItems[fresh.id] = PreparedItem(
          sourceId: fresh.id,
          requestIdentity: fresh.cacheIdentity,
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
      prepared.requestIdentity == source.cacheIdentity,
      prepared.sourceKind == source.kind
    else {
      preparedItems.removeValue(forKey: source.id)
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
      let interceptURL = resourceLoader.prepareURL(
        for: source.uri,
        headers: source.headers,
        cacheKey: source.cacheKey
      )
    {
      asset = AVURLAsset(url: interceptURL)
      asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoaderQueue)
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
        preparedItems.removeValue(forKey: sourceId)
        continue
      }
      if prepared.requestIdentity != source.cacheIdentity || prepared.sourceKind != source.kind {
        preparedItems.removeValue(forKey: sourceId)
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

  private func attachObservers(to managed: ManagedController, playerItem: AVPlayerItem) {
    assertMainQueue()
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
        guard !managed.didReportPlaybackError else {
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
    guard !managed.looping else {
      return
    }
    managed.endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self, weak managed] _ in
      guard let self,
        let managed,
        self.controllers[managed.id] === managed,
        !managed.didReportPlaybackError
      else {
        return
      }
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
