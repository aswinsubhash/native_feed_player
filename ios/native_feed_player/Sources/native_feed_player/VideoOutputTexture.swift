import AVFoundation
import Flutter
import Foundation

/// Publishes AVPlayer frames into a Flutter texture.
///
/// Platform views composite a native view into the Flutter scene, which costs a
/// synchronisation step per frame. Copying frames into a texture lets the
/// Flutter renderer draw the video like any other layer, which is usually
/// cheaper while scrolling. Both paths are kept so the choice can be measured
/// rather than assumed.
final class VideoOutputTexture: NSObject, FlutterTexture {
  private let output: AVPlayerItemVideoOutput
  private weak var player: AVPlayer?
  private var displayLink: CADisplayLink?
  private var latestBuffer: CVPixelBuffer?
  private let bufferLock = NSLock()

  /// Set once the texture is registered, so frame notifications can be routed.
  var textureId: Int64 = 0
  var onFrameAvailable: ((Int64) -> Void)?

  init(player: AVPlayer) {
    // BGRA is what the Flutter engine expects to upload without conversion.
    output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
    ])
    super.init()
    attach(to: player)
  }

  func attach(to player: AVPlayer) {
    detachOutput()
    self.player = player
    player.currentItem?.add(output)
    startDisplayLink()
  }

  func detachOutput() {
    displayLink?.invalidate()
    displayLink = nil
    player?.currentItem?.remove(output)
    player = nil
    bufferLock.lock()
    latestBuffer = nil
    bufferLock.unlock()
  }

  private func startDisplayLink() {
    let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc private func onDisplayLink(_ link: CADisplayLink) {
    // targetTimestamp is when this frame will actually be shown, which is the
    // time the pixel buffer should correspond to.
    let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
    guard output.hasNewPixelBuffer(forItemTime: itemTime),
      let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    else {
      return
    }

    bufferLock.lock()
    latestBuffer = buffer
    bufferLock.unlock()

    onFrameAvailable?(textureId)
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    guard let buffer = latestBuffer else {
      return nil
    }
    return Unmanaged.passRetained(buffer)
  }

  func onTextureUnregistered(_ texture: FlutterTexture) {
    detachOutput()
  }
}

/// Owns the texture objects bound to controllers.
final class TextureOutputRegistry {
  private let registry: FlutterTextureRegistry
  private var texturesByController: [Int: VideoOutputTexture] = [:]

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  /// Returns the Flutter texture id bound to `controllerId`.
  func attach(controllerId: Int, player: AVPlayer) -> Int64 {
    if let existing = texturesByController[controllerId] {
      existing.attach(to: player)
      return existing.textureId
    }

    let texture = VideoOutputTexture(player: player)
    let textureId = registry.register(texture)
    texture.textureId = textureId
    texture.onFrameAvailable = { [weak registry] id in
      registry?.textureFrameAvailable(id)
    }
    texturesByController[controllerId] = texture
    return textureId
  }

  func detach(controllerId: Int) {
    guard let texture = texturesByController.removeValue(forKey: controllerId) else {
      return
    }
    texture.detachOutput()
    registry.unregisterTexture(texture.textureId)
  }

  func clear() {
    for controllerId in texturesByController.keys {
      detach(controllerId: controllerId)
    }
  }
}
