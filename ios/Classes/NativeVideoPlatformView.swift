import Flutter
import UIKit

final class NativeVideoPlatformView: NSObject, FlutterPlatformView {
  let renderView: NativeVideoRenderView
  private let containerView: UIView
  private let onDispose: (NativeVideoRenderView) -> Void

  init(
    frame: CGRect,
    renderView: NativeVideoRenderView,
    onDispose: @escaping (NativeVideoRenderView) -> Void
  ) {
    self.renderView = renderView
    containerView = UIView(frame: frame)
    self.renderView.frame = containerView.bounds
    self.renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    containerView.addSubview(self.renderView)
    self.onDispose = onDispose
  }

  func view() -> UIView {
    containerView
  }

  func dispose() {
    onDispose(renderView)
  }
}
