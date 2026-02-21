import AVFoundation
import UIKit

final class NativeVideoRenderView: UIView {
  override class var layerClass: AnyClass {
    AVPlayerLayer.self
  }

  private var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }

  func setPlayer(_ player: AVPlayer?) {
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspectFill
  }
}
