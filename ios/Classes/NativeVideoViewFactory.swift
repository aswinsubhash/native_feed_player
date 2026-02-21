import Flutter
import UIKit

final class NativeVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  private let onCreate: (_ viewId: Int64, _ view: NativeVideoPlatformView) -> Void
  private let onDispose: (_ viewId: Int64) -> Void

  init(
    onCreate: @escaping (_ viewId: Int64, _ view: NativeVideoPlatformView) -> Void,
    onDispose: @escaping (_ viewId: Int64) -> Void
  ) {
    self.onCreate = onCreate
    self.onDispose = onDispose
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let view = NativeVideoPlatformView(frame: frame) { [weak self] in
      self?.onDispose(viewId)
    }
    onCreate(viewId, view)
    return view
  }
}
