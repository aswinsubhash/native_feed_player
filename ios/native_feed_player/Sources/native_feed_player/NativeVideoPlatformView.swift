import Flutter
import UIKit

final class NativeVideoPlatformView: NSObject, FlutterPlatformView {
  let renderView: NativeVideoRenderView
  private let containerView: UIView
  private let onDispose: (NativeVideoPlatformView) -> Void

  init(
    frame: CGRect,
    renderView: NativeVideoRenderView,
    onDispose: @escaping (NativeVideoPlatformView) -> Void
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
    onDispose(self)
  }
}
