import AVFoundation
import UIKit

final class NativeVideoRenderView: UIView {
  override class var layerClass: AnyClass {
    AVPlayerLayer.self
  }

  /// Exposed so the manager can observe `isReadyForDisplay`, which is the
  /// genuine first-frame signal for the metrics pipeline.
  var playerLayer: AVPlayerLayer {
    // Safe: layerClass guarantees the backing layer type.
    layer as! AVPlayerLayer
  }

  func setPlayer(_ player: AVPlayer?) {
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspectFill
  }
}
