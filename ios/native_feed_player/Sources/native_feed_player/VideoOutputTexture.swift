import AVFoundation
import Flutter
import Foundation

/// Weak display-link target avoids the CADisplayLink -> texture retain cycle so
/// texture deinitialization can always perform its final detach.
private final class VideoOutputDisplayLinkTarget: NSObject {
  weak var owner: VideoOutputTexture?

  init(owner: VideoOutputTexture) {
    self.owner = owner
  }

  @objc func tick(_ link: CADisplayLink) {
    owner?.onDisplayLink(link)
  }
}

/// Publishes `AVPlayer` frames to a Flutter texture.
final class VideoOutputTexture: NSObject, FlutterTexture {
  private let output: AVPlayerItemVideoOutput
  private weak var player: AVPlayer?
  private weak var attachedItem: AVPlayerItem?
  private var currentItemObservation: NSKeyValueObservation?
  private var displayLink: CADisplayLink?
  private var displayLinkTarget: VideoOutputDisplayLinkTarget?
  private var latestBuffer: CVPixelBuffer?
  private let bufferLock = NSLock()
  private var reportedFirstPixel = false

  /// Flutter texture identifier assigned after registration.
  var textureId: Int64 = 0
  var onFrameAvailable: ((Int64) -> Void)?
  var onFirstPixel: (() -> Void)?

  init(player: AVPlayer, onFirstPixel: (() -> Void)? = nil) {
    // Flutter uploads BGRA without conversion.
    output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
    ])
    super.init()
    attach(to: player, onFirstPixel: onFirstPixel)
  }

  deinit {
    detachOutput()
  }

  func attach(to player: AVPlayer, onFirstPixel: (() -> Void)? = nil) {
    detachOutput()
    reportedFirstPixel = false
    self.onFirstPixel = onFirstPixel
    self.player = player
    currentItemObservation = player.observe(
      \.currentItem,
      options: [.initial, .new]
    ) { [weak self] player, _ in
      DispatchQueue.main.async {
        self?.attachOutput(to: player.currentItem)
      }
    }
    startDisplayLink()
  }

  func detachOutput() {
    currentItemObservation?.invalidate()
    currentItemObservation = nil
    displayLink?.invalidate()
    displayLink = nil
    displayLinkTarget = nil
    attachedItem?.remove(output)
    attachedItem = nil
    player = nil
    reportedFirstPixel = false
    onFirstPixel = nil
    bufferLock.lock()
    latestBuffer = nil
    bufferLock.unlock()
  }

  private func attachOutput(to item: AVPlayerItem?) {
    if attachedItem === item {
      return
    }
    attachedItem?.remove(output)
    attachedItem = item
    attachedItem?.add(output)
  }

  private func startDisplayLink() {
    let target = VideoOutputDisplayLinkTarget(owner: self)
    let link = CADisplayLink(target: target, selector: #selector(VideoOutputDisplayLinkTarget.tick(_:)))
    link.add(to: .main, forMode: .common)
    displayLinkTarget = target
    displayLink = link
  }

  fileprivate func onDisplayLink(_ link: CADisplayLink) {
    // Select the frame for the display link's presentation time.
    let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
    guard output.hasNewPixelBuffer(forItemTime: itemTime),
      let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    else {
      return
    }

    bufferLock.lock()
    latestBuffer = buffer
    bufferLock.unlock()

    notifyFrameAvailable()
  }

  func installFirstPixelCallback(_ callback: @escaping () -> Void) {
    onFirstPixel = reportedFirstPixel ? nil : callback
  }

  /// Kept internal so the one-shot callback can be verified without requiring
  /// a hardware video decoder in unit tests.
  func notifyFrameAvailable() {
    if !reportedFirstPixel {
      reportedFirstPixel = true
      onFirstPixel?()
      onFirstPixel = nil
    }
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
    if Thread.isMainThread {
      detachOutput()
    } else {
      DispatchQueue.main.async { self.detachOutput() }
    }
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
  func attach(
    controllerId: Int,
    player: AVPlayer,
    onFirstPixel: @escaping () -> Void
  ) -> Int64 {
    if let existing = texturesByController[controllerId] {
      existing.attach(to: player, onFirstPixel: onFirstPixel)
      return existing.textureId
    }

    let texture = VideoOutputTexture(
      player: player,
      onFirstPixel: onFirstPixel
    )
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
    texture.onFirstPixel = nil
    texture.onFrameAvailable = nil
    registry.unregisterTexture(texture.textureId)
  }

  func clear() {
    for controllerId in Array(texturesByController.keys) {
      detach(controllerId: controllerId)
    }
  }
}
