import AVFoundation
import UIKit

final class NativeVideoRenderView: UIView {
  override class var layerClass: AnyClass {
    AVPlayerLayer.self
  }

  /// Typed backing layer used for display-readiness observation.
  var playerLayer: AVPlayerLayer {
    // layerClass fixes the backing layer type.
    layer as! AVPlayerLayer
  }

  func setPlayer(_ player: AVPlayer?) {
    playerLayer.player = player
  }

  func setFit(_ fit: String?) {
    switch fit {
    case "contain", "fitWidth", "fitHeight", "none", "scaleDown":
      playerLayer.videoGravity = .resizeAspect
    case "fill":
      playerLayer.videoGravity = .resize
    case "cover", nil:
      playerLayer.videoGravity = .resizeAspectFill
    default:
      playerLayer.videoGravity = .resizeAspect
    }
  }
}
