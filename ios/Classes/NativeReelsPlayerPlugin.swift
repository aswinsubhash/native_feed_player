import Flutter
import Foundation
import UIKit

private final class EventSinkStreamHandler: NSObject, FlutterStreamHandler {
  var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

public final class NativeReelsPlayerPlugin: NSObject, FlutterPlugin, NativeReelsPlayerHostApi {
  private static let videoViewType = "native_reels_player/video_view"

  private let stateStreamHandler = EventSinkStreamHandler()
  private let positionStreamHandler = EventSinkStreamHandler()
  private let metricsStreamHandler = EventSinkStreamHandler()

  private var nextControllerId: Int = 1
  private var manager: AVPlayerManager?
  private var memoryWarningObserver: NSObjectProtocol?
  private var videoViews: [Int64: NativeVideoPlatformView] = [:]
  private var attachedControllerByViewId: [Int64: Int] = [:]
  private var binaryMessenger: FlutterBinaryMessenger?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let stateChannel = FlutterEventChannel(
      name: "native_reels_player/state",
      binaryMessenger: registrar.messenger()
    )
    let positionChannel = FlutterEventChannel(
      name: "native_reels_player/position",
      binaryMessenger: registrar.messenger()
    )
    let metricsChannel = FlutterEventChannel(
      name: "native_reels_player/metrics",
      binaryMessenger: registrar.messenger()
    )

    let instance = NativeReelsPlayerPlugin()
    instance.binaryMessenger = registrar.messenger()
    instance.configureChannels(
      stateChannel: stateChannel,
      positionChannel: positionChannel,
      metricsChannel: metricsChannel
    )
    let viewFactory = NativeVideoViewFactory(
      onCreate: { [weak instance] viewId, view in
        instance?.videoViews[viewId] = view
      },
      onDispose: { [weak instance] viewId in
        instance?.handleVideoViewDisposed(viewId: viewId)
      }
    )
    registrar.register(viewFactory, withId: videoViewType)
    NativeReelsPlayerHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
  }

  deinit {
    if let observer = memoryWarningObserver {
      NotificationCenter.default.removeObserver(observer)
      memoryWarningObserver = nil
    }
    if let binaryMessenger {
      NativeReelsPlayerHostApiSetup.setUp(binaryMessenger: binaryMessenger, api: nil)
    }
    videoViews.removeAll()
    attachedControllerByViewId.removeAll()
    manager?.disposeAll()
  }

  func initialize(request: InitializeRequest) throws {
    try managerOrThrow().initialize(
      maxCachedPlayers: Int(request.maxCachedPlayers),
      preloadCount: Int(request.preloadCount)
    )
  }

  func preload(request: PreloadRequest) throws {
    let sources: [[String: Any]] = request.sources.map { source in
      [
        "index": Int(source.index),
        "url": source.url,
      ]
    }
    try managerOrThrow().preload(sources: sources)
  }

  func createController(request: CreateControllerRequest) throws -> Int64 {
    let url = request.url
    if url.isEmpty {
      throw PigeonError(
        code: "invalid_url",
        message: "createController requires a non-empty URL.",
        details: nil
      )
    }

    let controllerId = nextControllerId
    nextControllerId += 1

    do {
      try managerOrThrow().createController(
        controllerId: controllerId,
        url: url,
        index: Int(request.index),
        autoPlay: request.autoPlay,
        looping: request.looping
      )
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

  func setVisibleIndex(request: VisibleIndexRequest) throws {
    try managerOrThrow().setVisibleIndex(index: Int(request.index))
  }

  func clearCache() throws {
    try managerOrThrow().clearCache()
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
    if let previousController = attachedControllerByViewId[viewId], previousController != controllerId {
      manager.detach(controllerId: previousController)
    }
    attachedControllerByViewId[viewId] = controllerId
    manager.attach(controllerId: controllerId, renderView: platformView.renderView)
  }

  func detachView(request: ControllerRequest) throws {
    let controllerId = Int(request.controllerId)
    if controllerId > 0 {
      let manager = try managerOrThrow()
      manager.detach(controllerId: controllerId)
      let staleViews = attachedControllerByViewId
        .filter { $0.value == controllerId }
        .map { $0.key }
      for viewId in staleViews {
        attachedControllerByViewId.removeValue(forKey: viewId)
      }
    }
  }

  func disposeAll() throws {
    try managerOrThrow().disposeAll()
    attachedControllerByViewId.removeAll()
  }

  private func configureChannels(
    stateChannel: FlutterEventChannel,
    positionChannel: FlutterEventChannel,
    metricsChannel: FlutterEventChannel
  ) {
    manager = AVPlayerManager(
      onState: { [weak self] controllerId, state in
        self?.emitState(controllerId: controllerId, state: state)
      },
      onPosition: { [weak self] controllerId, positionMs in
        self?.emitPosition(controllerId: controllerId, positionMs: positionMs)
      },
      onMetrics: { [weak self] _, payload in
        self?.emitMetrics(payload: payload)
      }
    )

    stateChannel.setStreamHandler(stateStreamHandler)
    positionChannel.setStreamHandler(positionStreamHandler)
    metricsChannel.setStreamHandler(metricsStreamHandler)

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

  private func emitState(controllerId: Int, state: String) {
    let payload: [String: Any] = [
      "controllerId": controllerId,
      "state": state,
    ]
    if Thread.isMainThread {
      stateStreamHandler.sink?(payload)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.stateStreamHandler.sink?(payload)
      }
    }
  }

  private func emitPosition(controllerId: Int, positionMs: Int64) {
    let payload: [String: Any] = [
      "controllerId": controllerId,
      "positionMs": positionMs,
    ]
    if Thread.isMainThread {
      positionStreamHandler.sink?(payload)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.positionStreamHandler.sink?(payload)
      }
    }
  }

  private func emitMetrics(payload: [String: Any]) {
    if Thread.isMainThread {
      metricsStreamHandler.sink?(payload)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.metricsStreamHandler.sink?(payload)
      }
    }
  }

  private func handleVideoViewDisposed(viewId: Int64) {
    let controllerId = attachedControllerByViewId.removeValue(forKey: viewId)
    if let controllerId {
      manager?.detach(controllerId: controllerId)
    }
    videoViews.removeValue(forKey: viewId)
  }

  private func managerOrThrow() throws -> AVPlayerManager {
    guard let manager else {
      throw PigeonError(
        code: "not_attached",
        message: "NativeReelsPlayerPlugin is not attached to a Flutter engine.",
        details: nil
      )
    }
    return manager
  }
}
