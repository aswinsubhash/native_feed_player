import Flutter
import Foundation
import UIKit

/// Holds the Pigeon sink for one event channel and buffers events emitted
/// before Dart subscribes.
///
/// Native playback starts reporting state during `createController`, which runs
/// before the caller has had a chance to listen to that controller's stream, so
/// without a small buffer the first transition is silently lost.
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

/// Pigeon generates a distinct handler class per event channel, so each one
/// needs a concrete adapter that forwards its sink into a shared holder.
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

  /// Controller ids must stay unique for the life of the process, not the life
  /// of one engine attachment, so a re-attaching engine cannot mint ids that
  /// collide with handles Dart still holds.
  private static var controllerIdSeed = 0

  private let stateEvents = BufferedEventSink<PlaybackStateEvent>()
  private let positionEvents = BufferedEventSink<PositionEvent>()
  private let metricsEvents = BufferedEventSink<MetricsEvent>()
  private let lifecycleEvents = BufferedEventSink<ControllerLifecycleEvent>()

  private var manager: AVPlayerManager?
  private var memoryWarningObserver: NSObjectProtocol?
  private let renderViewPool = RenderViewPool(maxPoolSize: 8)
  private var videoViews: [Int64: NativeVideoPlatformView] = [:]
  private var attachedControllerByViewId: [Int64: Int] = [:]
  private var binaryMessenger: FlutterBinaryMessenger?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NativeFeedPlayerPlugin()
    instance.binaryMessenger = registrar.messenger()
    instance.configure(messenger: registrar.messenger())

    let viewFactory = NativeVideoViewFactory(
      renderViewPool: instance.renderViewPool,
      onCreate: { [weak instance] viewId, view in
        instance?.videoViews[viewId] = view
      },
      onDispose: { [weak instance] viewId, renderView in
        instance?.handleVideoViewDisposed(viewId: viewId, renderView: renderView)
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
    videoViews.removeAll()
    attachedControllerByViewId.removeAll()
    renderViewPool.clear()
    manager?.disposeAll()
  }

  // MARK: - Host API

  func initialize(config: FeedPlayerConfigMessage) throws {
    try managerOrThrow().initialize(config: config)
  }

  func setSources(sources: [FeedSourceMessage]) throws {
    try managerOrThrow().setSources(sources.map { $0.toRegisteredSource() })
  }

  func appendSources(sources: [FeedSourceMessage]) throws {
    try managerOrThrow().appendSources(sources.map { $0.toRegisteredSource() })
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

  func setVisibleSource(request: VisibleSourceRequest) throws {
    try managerOrThrow().setVisibleSource(request.sourceId)
  }

  func evictCachedMedia(request: SourceIdsRequest) throws {
    try managerOrThrow().evictCachedMedia(request.sourceIds)
  }

  func clearMediaCache() throws {
    try managerOrThrow().clearMediaCache()
  }

  func cacheStatus(request: VisibleSourceRequest) throws -> CacheStatusMessage {
    try managerOrThrow().cacheStatus(sourceId: request.sourceId)
  }

  func cacheUsageBytes() throws -> Int64 {
    try managerOrThrow().cacheUsageBytes()
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
    for (viewId, attached) in attachedControllerByViewId where attached == controllerId {
      attachedControllerByViewId.removeValue(forKey: viewId)
    }
  }

  func disposeAll() throws {
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
          self?.lifecycleEvents.emit(
            ControllerLifecycleEvent(controllerId: Int64(controllerId), reason: reason)
          )
        }
      },
      onPosition: { [weak self] event in
        self?.onMain { self?.positionEvents.emit(event) }
      },
      onMetrics: { [weak self] event in
        self?.onMain { self?.metricsEvents.emit(event) }
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

  private func handleVideoViewDisposed(viewId: Int64, renderView: NativeVideoRenderView) {
    if let controllerId = attachedControllerByViewId.removeValue(forKey: viewId) {
      manager?.detach(controllerId: controllerId)
    }
    videoViews.removeValue(forKey: viewId)
    renderViewPool.release(renderView)
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
