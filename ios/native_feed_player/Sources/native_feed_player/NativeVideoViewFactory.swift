import Flutter
import UIKit

final class NativeVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  private let renderViewPool: RenderViewPool
  private let onCreate: (_ viewId: Int64, _ view: NativeVideoPlatformView) -> Void
  private let onDispose: (_ viewId: Int64, _ view: NativeVideoPlatformView) -> Void

  init(
    renderViewPool: RenderViewPool,
    onCreate: @escaping (_ viewId: Int64, _ view: NativeVideoPlatformView) -> Void,
    onDispose: @escaping (_ viewId: Int64, _ view: NativeVideoPlatformView) -> Void
  ) {
    self.renderViewPool = renderViewPool
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
    let renderView = renderViewPool.acquire(frame: frame)
    let fit = (args as? [String: Any])?["fit"] as? String
    renderView.setFit(fit)
    let view = NativeVideoPlatformView(frame: frame, renderView: renderView) { [weak self] disposedView in
      self?.onDispose(viewId, disposedView)
    }
    onCreate(viewId, view)
    return view
  }
}
