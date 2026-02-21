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

public final class NativeReelsPlayerPlugin: NSObject, FlutterPlugin {
  private let stateStreamHandler = EventSinkStreamHandler()
  private let positionStreamHandler = EventSinkStreamHandler()

  private var nextControllerId: Int = 1
  private var manager: AVPlayerManager?
  private var memoryWarningObserver: NSObjectProtocol?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "native_reels_player",
      binaryMessenger: registrar.messenger()
    )
    let stateChannel = FlutterEventChannel(
      name: "native_reels_player/state",
      binaryMessenger: registrar.messenger()
    )
    let positionChannel = FlutterEventChannel(
      name: "native_reels_player/position",
      binaryMessenger: registrar.messenger()
    )

    let instance = NativeReelsPlayerPlugin()
    instance.configureChannels(stateChannel: stateChannel, positionChannel: positionChannel)
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
  }

  deinit {
    if let observer = memoryWarningObserver {
      NotificationCenter.default.removeObserver(observer)
      memoryWarningObserver = nil
    }
    manager?.disposeAll()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let manager else {
      result(
        FlutterError(
          code: "not_attached",
          message: "NativeReelsPlayerPlugin is not attached to a Flutter engine.",
          details: nil
        )
      )
      return
    }

    switch call.method {
    case "initialize":
      let args = call.args()
      manager.initialize(
        maxCachedPlayers: args.intValue("maxCachedPlayers", defaultValue: 5),
        preloadCount: args.intValue("preloadCount", defaultValue: 2)
      )
      result(nil)

    case "preload":
      let args = call.args()
      let rawSources = args["sources"] as? [[String: Any]] ?? []
      manager.preload(sources: rawSources)
      result(nil)

    case "createController":
      let args = call.args()
      let url = args["url"] as? String ?? ""
      if url.isEmpty {
        result(
          FlutterError(
            code: "invalid_url",
            message: "createController requires a non-empty URL.",
            details: nil
          )
        )
        return
      }

      let controllerId = nextControllerId
      nextControllerId += 1

      do {
        try manager.createController(
          controllerId: controllerId,
          url: url,
          index: args.intValue("index", defaultValue: -1),
          autoPlay: args.boolValue("autoPlay", defaultValue: false),
          looping: args.boolValue("looping", defaultValue: true)
        )
        result(controllerId)
      } catch {
        result(
          FlutterError(
            code: "create_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }

    case "disposeController":
      let controllerId = call.args().intValue("controllerId", defaultValue: -1)
      if controllerId > 0 {
        manager.disposeController(controllerId: controllerId)
      }
      result(nil)

    case "play":
      let controllerId = call.args().intValue("controllerId", defaultValue: -1)
      if controllerId > 0 {
        manager.play(controllerId: controllerId)
      }
      result(nil)

    case "pause":
      let controllerId = call.args().intValue("controllerId", defaultValue: -1)
      if controllerId > 0 {
        manager.pause(controllerId: controllerId)
      }
      result(nil)

    case "seekTo":
      let args = call.args()
      let controllerId = args.intValue("controllerId", defaultValue: -1)
      let positionMs = args.int64Value("positionMs", defaultValue: 0)
      if controllerId > 0 {
        manager.seekTo(controllerId: controllerId, positionMs: positionMs)
      }
      result(nil)

    case "setVisibleIndex":
      let index = call.args().intValue("index", defaultValue: 0)
      manager.setVisibleIndex(index: index)
      result(nil)

    case "clearCache":
      manager.clearCache()
      result(nil)

    case "disposeAll":
      manager.disposeAll()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func configureChannels(
    stateChannel: FlutterEventChannel,
    positionChannel: FlutterEventChannel
  ) {
    manager = AVPlayerManager(
      onState: { [weak self] controllerId, state in
        self?.emitState(controllerId: controllerId, state: state)
      },
      onPosition: { [weak self] controllerId, positionMs in
        self?.emitPosition(controllerId: controllerId, positionMs: positionMs)
      }
    )

    stateChannel.setStreamHandler(stateStreamHandler)
    positionChannel.setStreamHandler(positionStreamHandler)

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
}

private extension FlutterMethodCall {
  func args() -> [String: Any] {
    arguments as? [String: Any] ?? [:]
  }
}

private extension Dictionary where Key == String, Value == Any {
  func intValue(_ key: String, defaultValue: Int) -> Int {
    if let value = self[key] as? Int {
      return value
    }
    if let value = self[key] as? NSNumber {
      return value.intValue
    }
    return defaultValue
  }

  func int64Value(_ key: String, defaultValue: Int64) -> Int64 {
    if let value = self[key] as? Int64 {
      return value
    }
    if let value = self[key] as? NSNumber {
      return value.int64Value
    }
    return defaultValue
  }

  func boolValue(_ key: String, defaultValue: Bool) -> Bool {
    if let value = self[key] as? Bool {
      return value
    }
    if let value = self[key] as? NSNumber {
      return value.boolValue
    }
    return defaultValue
  }
}
