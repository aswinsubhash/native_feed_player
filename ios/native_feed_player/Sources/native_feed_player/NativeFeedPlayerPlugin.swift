import Flutter
import Foundation
import UIKit

/// Buffers events until the Dart event stream attaches.
final class BufferedEventSink<T> {
  private let maxBuffered: Int
  private var pending: [T] = []
  private var sink: PigeonEventSink<T>?

  init(maxBuffered: Int = 64) {
    self.maxBuffered = maxBuffered
  }

  func attach(_ sink: PigeonEventSink<T>) {
    self.sink = sink
    let buffered = pending
    pending.removeAll()
    for event in buffered {
      sink.success(event)
    }
  }

  func detach() {
    sink = nil
    pending.removeAll()
  }

  func clearPending() {
    pending.removeAll()
  }

  func emit(_ event: T) {
    if let sink {
      sink.success(event)
      return
    }
    if pending.count >= maxBuffered {
      pending.removeFirst()
    }
    pending.append(event)
  }
}

/// Adapts a Pigeon event channel to `BufferedEventSink`.
private final class PlaybackStateStreamAdapter: PlaybackStateEventsStreamHandler {
  private let holder: BufferedEventSink<PlaybackStateEvent>

  init(holder: BufferedEventSink<PlaybackStateEvent>) {
    self.holder = holder
  }

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<PlaybackStateEvent>) {
    holder.attach(sink)
  }

  override func onCancel(withArguments arguments: Any?) {
    holder.detach()
  }
}

private final class PositionStreamAdapter: PositionEventsStreamHandler {
  private let holder: BufferedEventSink<PositionEvent>

  init(holder: BufferedEventSink<PositionEvent>) {
    self.holder = holder
  }

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<PositionEvent>) {
    holder.attach(sink)
  }

  override func onCancel(withArguments arguments: Any?) {
    holder.detach()
  }
}

private final class MetricsStreamAdapter: MetricsEventsStreamHandler {
  private let holder: BufferedEventSink<MetricsEvent>

  init(holder: BufferedEventSink<MetricsEvent>) {
    self.holder = holder
  }

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<MetricsEvent>) {
    holder.attach(sink)
  }

  override func onCancel(withArguments arguments: Any?) {
    holder.detach()
  }
}

private final class VideoSizeStreamAdapter: VideoSizeEventsStreamHandler {
  private let holder: BufferedEventSink<VideoSizeEvent>

  init(holder: BufferedEventSink<VideoSizeEvent>) {
    self.holder = holder
  }

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<VideoSizeEvent>) {
    holder.attach(sink)
  }

  override func onCancel(withArguments arguments: Any?) {
    holder.detach()
  }
}

private final class LifecycleStreamAdapter: LifecycleEventsStreamHandler {
  private let holder: BufferedEventSink<ControllerLifecycleEvent>

  init(holder: BufferedEventSink<ControllerLifecycleEvent>) {
    self.holder = holder
  }

  override func onListen(
    withArguments arguments: Any?,
    sink: PigeonEventSink<ControllerLifecycleEvent>
  ) {
    holder.attach(sink)
  }

  override func onCancel(withArguments arguments: Any?) {
    holder.detach()
  }
}

public final class NativeFeedPlayerPlugin: NSObject, FlutterPlugin, NativeFeedPlayerHostApi {
  private static let videoViewType = "native_feed_player/video_view"

  /// Process-wide ID seed retained across engine reattachment.
  private static var controllerIdSeed = 0

  private let stateEvents = BufferedEventSink<PlaybackStateEvent>()
  private let positionEvents = BufferedEventSink<PositionEvent>()
  private let metricsEvents = BufferedEventSink<MetricsEvent>()
  private let videoSizeEvents = BufferedEventSink<VideoSizeEvent>()
  private let lifecycleEvents = BufferedEventSink<ControllerLifecycleEvent>()

  private var manager: AVPlayerManager?
  private var memoryWarningObserver: NSObjectProtocol?
  private let renderViewPool = RenderViewPool(maxPoolSize: 8)
  private let videoViews = PlatformViewRegistry<Int64, NativeVideoPlatformView>()
  private var attachedControllerByViewId: [Int64: Int] = [:]
  private var binaryMessenger: FlutterBinaryMessenger?
  private var textureOutputs: TextureOutputRegistry?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NativeFeedPlayerPlugin()
    instance.binaryMessenger = registrar.messenger()
    instance.textureOutputs = TextureOutputRegistry(registry: registrar.textures())
    instance.configure(messenger: registrar.messenger())

    let viewFactory = NativeVideoViewFactory(
      renderViewPool: instance.renderViewPool,
      onCreate: { [weak instance] viewId, view in
        instance?.handleVideoViewCreated(viewId: viewId, view: view)
      },
      onDispose: { [weak instance] viewId, view in
        instance?.handleVideoViewDisposed(viewId: viewId, view: view)
      }
    )
    registrar.register(viewFactory, withId: videoViewType)
    NativeFeedPlayerHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
  }

  deinit {
    if let observer = memoryWarningObserver {
      NotificationCenter.default.removeObserver(observer)
      memoryWarningObserver = nil
    }
    if let binaryMessenger {
      NativeFeedPlayerHostApiSetup.setUp(binaryMessenger: binaryMessenger, api: nil)
    }
    textureOutputs?.clear()
    manager?.disposeAll()
    videoViews.removeAll()
    attachedControllerByViewId.removeAll()
    renderViewPool.clear()
  }

  // MARK: - Host API

  func initialize(config: FeedPlayerConfigMessage) throws {
    textureOutputs?.clear()
    attachedControllerByViewId.removeAll()
    try managerOrThrow().initialize(config: config)
    stateEvents.clearPending()
    positionEvents.clearPending()
    metricsEvents.clearPending()
    videoSizeEvents.clearPending()
    lifecycleEvents.clearPending()
  }

  func setSources(sources: [FeedSourceMessage]) throws {
    do {
      try managerOrThrow().setSources(sources.map { $0.toRegisteredSource() })
    } catch let error as AVPlayerManager.PlaybackSetupError {
      throw PigeonError(code: error.code, message: error.message, details: nil)
    }
  }

  func appendSources(sources: [FeedSourceMessage]) throws {
    do {
      try managerOrThrow().appendSources(sources.map { $0.toRegisteredSource() })
    } catch let error as AVPlayerManager.PlaybackSetupError {
      throw PigeonError(code: error.code, message: error.message, details: nil)
    }
  }

  func removeSources(request: SourceIdsRequest) throws {
    try managerOrThrow().removeSources(request.sourceIds)
  }

  func createController(request: CreateControllerRequest) throws -> Int64 {
    if request.sourceId.isEmpty {
      throw PigeonError(
        code: "invalid_source",
        message: "createController requires a source id.",
        details: nil
      )
    }

    NativeFeedPlayerPlugin.controllerIdSeed += 1
    let controllerId = NativeFeedPlayerPlugin.controllerIdSeed

    do {
      try managerOrThrow().createController(
        controllerId: controllerId,
        sourceId: request.sourceId,
        autoPlay: request.autoPlay,
        looping: request.looping
      )
    } catch let setupError as AVPlayerManager.PlaybackSetupError {
      throw PigeonError(code: setupError.code, message: setupError.message, details: nil)
    } catch {
      throw PigeonError(
        code: "create_failed",
        message: error.localizedDescription,
        details: nil
      )
    }

    return Int64(controllerId)
  }

  func disposeController(request: ControllerRequest) throws {
    let controllerId = Int(request.controllerId)
    if controllerId > 0 {
      try managerOrThrow().disposeController(controllerId: controllerId)
    }
  }

  func play(request: ControllerRequest) throws {
    let controllerId = Int(request.controllerId)
    if controllerId > 0 {
      try managerOrThrow().play(controllerId: controllerId)
    }
  }

  func pause(request: ControllerRequest) throws {
    let controllerId = Int(request.controllerId)
    if controllerId > 0 {
      try managerOrThrow().pause(controllerId: controllerId)
    }
  }

  func seekTo(request: SeekRequest) throws {
    let controllerId = Int(request.controllerId)
    if controllerId > 0 {
      try managerOrThrow().seekTo(controllerId: controllerId, positionMs: request.positionMs)
    }
  }

  func setVolume(request: ControllerDoubleRequest) throws {
    try managerOrThrow().setVolume(controllerId: Int(request.controllerId), value: request.value)
  }

  func setMuted(request: ControllerFlagRequest) throws {
    try managerOrThrow().setMuted(controllerId: Int(request.controllerId), value: request.value)
  }

  func setPlaybackSpeed(request: ControllerDoubleRequest) throws {
    try managerOrThrow().setPlaybackSpeed(
      controllerId: Int(request.controllerId),
      speed: request.value
    )
  }

  func setLooping(request: ControllerFlagRequest) throws {
    try managerOrThrow().setLooping(
      controllerId: Int(request.controllerId),
      looping: request.value
    )
  }

  func setAudioPolicy(policy: AudioPolicyMessage) throws {
    try managerOrThrow().applyAudioPolicy(policy)
  }

  func setVisibleSource(request: VisibleSourceRequest) throws {
    try managerOrThrow().setVisibleSource(request.sourceId)
  }

  func evictCachedMedia(
    request: SourceIdsRequest,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      try managerOrThrow().evictCachedMedia(request.sourceIds) {
        DispatchQueue.main.async { completion(.success(())) }
      }
    } catch {
      DispatchQueue.main.async { completion(.failure(error)) }
    }
  }

  func clearMediaCache(completion: @escaping (Result<Void, Error>) -> Void) {
    do {
      try managerOrThrow().clearMediaCache {
        DispatchQueue.main.async { completion(.success(())) }
      }
    } catch {
      DispatchQueue.main.async { completion(.failure(error)) }
    }
  }

  func cacheStatus(
    request: VisibleSourceRequest,
    completion: @escaping (Result<CacheStatusMessage, Error>) -> Void
  ) {
    do {
      try managerOrThrow().cacheStatus(sourceId: request.sourceId) { status in
        DispatchQueue.main.async { completion(.success(status)) }
      }
    } catch {
      DispatchQueue.main.async { completion(.failure(error)) }
    }
  }

  func cacheUsageBytes(completion: @escaping (Result<Int64, Error>) -> Void) {
    do {
      try managerOrThrow().cacheUsageBytes { bytes in
        DispatchQueue.main.async { completion(.success(bytes)) }
      }
    } catch {
      DispatchQueue.main.async { completion(.failure(error)) }
    }
  }

  func attachView(request: AttachViewRequest) throws {
    let controllerId = Int(request.controllerId)
    let viewId = Int64(request.viewId)
    guard controllerId > 0, viewId >= 0 else {
      throw PigeonError(
        code: "invalid_attach",
        message: "attachView requires valid controllerId and viewId.",
        details: nil
      )
    }
    guard let platformView = videoViews[viewId] else {
      throw PigeonError(
        code: "view_not_found",
        message: "No video view found for id=\(viewId).",
        details: nil
      )
    }

    let manager = try managerOrThrow()
    if let previous = attachedControllerByViewId[viewId], previous != controllerId {
      manager.detach(controllerId: previous)
    }
    // A controller can render into only one platform view. Remove stale plugin
    // mappings when Flutter reuses/replaces a view before disposal arrives.
    let staleViewIds = attachedControllerByViewId.compactMap { otherViewId, attached in
      attached == controllerId && otherViewId != viewId ? otherViewId : nil
    }
    for staleViewId in staleViewIds {
      videoViews[staleViewId]?.renderView.setPlayer(nil)
      attachedControllerByViewId.removeValue(forKey: staleViewId)
    }
    attachedControllerByViewId[viewId] = controllerId
    manager.attach(controllerId: controllerId, renderView: platformView.renderView)
  }

  func detachView(request: ControllerRequest) throws {
    let controllerId = Int(request.controllerId)
    guard controllerId > 0 else {
      return
    }
    let manager = try managerOrThrow()
    manager.detach(controllerId: controllerId)
    let attachedViewIds = attachedControllerByViewId.compactMap { viewId, attached in
      attached == controllerId ? viewId : nil
    }
    for viewId in attachedViewIds {
      videoViews[viewId]?.renderView.setPlayer(nil)
      attachedControllerByViewId.removeValue(forKey: viewId)
    }
  }

  func attachTexture(request: ControllerRequest) throws -> Int64 {
    let controllerId = Int(request.controllerId)
    guard let textureOutputs else {
      throw PigeonError(
        code: "not_attached",
        message: "No texture registry available.",
        details: nil
      )
    }
    let manager = try managerOrThrow()
    guard let player = manager.player(for: controllerId) else {
      throw PigeonError(
        code: "controller_not_found",
        message: "No live controller with id=\(controllerId).",
        details: nil
      )
    }
    return textureOutputs.attach(
      controllerId: controllerId,
      player: player,
      onFirstPixel: { [weak manager] in
        manager?.markTextureFirstFrame(controllerId: controllerId)
      }
    )
  }

  func detachTexture(request: ControllerRequest) throws {
    textureOutputs?.detach(controllerId: Int(request.controllerId))
  }

  func disposeAll() throws {
    textureOutputs?.clear()
    try managerOrThrow().disposeAll()
    attachedControllerByViewId.removeAll()
  }

  // MARK: - Wiring

  private func configure(messenger: FlutterBinaryMessenger) {
    PlaybackStateEventsStreamHandler.register(
      with: messenger,
      streamHandler: PlaybackStateStreamAdapter(holder: stateEvents)
    )
    PositionEventsStreamHandler.register(
      with: messenger,
      streamHandler: PositionStreamAdapter(holder: positionEvents)
    )
    MetricsEventsStreamHandler.register(
      with: messenger,
      streamHandler: MetricsStreamAdapter(holder: metricsEvents)
    )
    VideoSizeEventsStreamHandler.register(
      with: messenger,
      streamHandler: VideoSizeStreamAdapter(holder: videoSizeEvents)
    )
    LifecycleEventsStreamHandler.register(
      with: messenger,
      streamHandler: LifecycleStreamAdapter(holder: lifecycleEvents)
    )

    manager = AVPlayerManager(
      onState: { [weak self] controllerId, status, error in
        self?.onMain {
          self?.stateEvents.emit(
            PlaybackStateEvent(
              controllerId: Int64(controllerId),
              status: status,
              error: error
            )
          )
        }
      },
      onReleased: { [weak self] controllerId, reason in
        self?.onMain {
          self?.handleManagerRelease(controllerId: controllerId, reason: reason)
        }
      },
      onPosition: { [weak self] event in
        self?.onMain { self?.positionEvents.emit(event) }
      },
      onMetrics: { [weak self] event in
        self?.onMain { self?.metricsEvents.emit(event) }
      },
      onVideoSize: { [weak self] event in
        self?.onMain { self?.videoSizeEvents.emit(event) }
      }
    )

    if let observer = memoryWarningObserver {
      NotificationCenter.default.removeObserver(observer)
      memoryWarningObserver = nil
    }
    memoryWarningObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.manager?.onMemoryWarning()
    }
  }

  private func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  /// A manager release must sever every Flutter rendering edge before Dart is
  /// told that the controller is gone.
  private func handleManagerRelease(controllerId: Int, reason: ReleaseReasonMessage) {
    textureOutputs?.detach(controllerId: controllerId)
    let staleViewIds = attachedControllerByViewId.compactMap { viewId, attached in
      attached == controllerId ? viewId : nil
    }
    for viewId in staleViewIds {
      videoViews[viewId]?.renderView.setPlayer(nil)
      attachedControllerByViewId.removeValue(forKey: viewId)
    }
    lifecycleEvents.emit(
      ControllerLifecycleEvent(controllerId: Int64(controllerId), reason: reason)
    )
  }

  private func handleVideoViewCreated(viewId: Int64, view: NativeVideoPlatformView) {
    if let previousControllerId = attachedControllerByViewId.removeValue(forKey: viewId) {
      manager?.detach(controllerId: previousControllerId)
    }
    videoViews.register(view, for: viewId)
  }

  private func handleVideoViewDisposed(viewId: Int64, view: NativeVideoPlatformView) {
    guard videoViews.removeIfCurrent(view, for: viewId) else {
      renderViewPool.release(view.renderView)
      return
    }
    if let controllerId = attachedControllerByViewId.removeValue(forKey: viewId) {
      manager?.detach(controllerId: controllerId, renderView: view.renderView)
    }
    renderViewPool.release(view.renderView)
  }

  private func managerOrThrow() throws -> AVPlayerManager {
    guard let manager else {
      throw PigeonError(
        code: "not_attached",
        message: "NativeFeedPlayerPlugin is not attached to a Flutter engine.",
        details: nil
      )
    }
    return manager
  }
}

extension FeedSourceMessage {
  fileprivate func toRegisteredSource() -> RegisteredSource {
    RegisteredSource(
      id: id,
      uri: uri,
      rank: Int(rank),
      kind: kind,
      headers: headers
    )
  }
}
