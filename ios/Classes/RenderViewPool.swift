import UIKit

final class RenderViewPool {
  private let maxPoolSize: Int
  private var pooledViews: [NativeVideoRenderView] = []

  init(maxPoolSize: Int) {
    self.maxPoolSize = maxPoolSize
  }

  func acquire(frame: CGRect) -> NativeVideoRenderView {
    let view = pooledViews.popLast() ?? NativeVideoRenderView(frame: frame)
    view.frame = frame
    view.setPlayer(nil)
    return view
  }

  func release(_ view: NativeVideoRenderView) {
    view.setPlayer(nil)
    view.removeFromSuperview()
    guard pooledViews.count < maxPoolSize else {
      return
    }
    pooledViews.append(view)
  }

  func clear() {
    pooledViews.removeAll()
  }
}
