import Flutter
import UIKit

final class NativeVideoPlatformView: NSObject, FlutterPlatformView {
  let renderView: NativeVideoRenderView
  private let onDispose: () -> Void

  init(frame: CGRect, onDispose: @escaping () -> Void) {
    renderView = NativeVideoRenderView(frame: frame)
    self.onDispose = onDispose
  }

  func view() -> UIView {
    renderView
  }

  func dispose() {
    onDispose()
  }
}
