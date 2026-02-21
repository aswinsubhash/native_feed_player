import AVFoundation
import Foundation

/// AVPlayer lifecycle and event orchestration for a single-process player map.
final class AVPlayerManager {
  typealias StateCallback = (_ controllerId: Int, _ state: String) -> Void
  typealias PositionCallback = (_ controllerId: Int, _ positionMs: Int64) -> Void

  private final class ManagedController {
    let id: Int
    let url: String
    let player: AVPlayer
    let looping: Bool
    var itemStatusObservation: NSKeyValueObservation?
    var timeControlObservation: NSKeyValueObservation?
    var endObserver: NSObjectProtocol?

    init(id: Int, url: String, player: AVPlayer, looping: Bool) {
      self.id = id
      self.url = url
      self.player = player
      self.looping = looping
    }
  }

  private let onState: StateCallback
  private let onPosition: PositionCallback

  private var controllers: [Int: ManagedController] = [:]
  private var creationOrder: [Int] = []
  private var preloadedAssets: [String: AVURLAsset] = [:]
  private var maxCachedPlayers: Int = 5
  private var preloadCount: Int = 2
  private var positionTimer: Timer?

  init(onState: @escaping StateCallback, onPosition: @escaping PositionCallback) {
    self.onState = onState
    self.onPosition = onPosition
  }

  deinit {
    disposeAll()
  }

  func initialize(maxCachedPlayers: Int, preloadCount: Int) {
    self.maxCachedPlayers = max(1, maxCachedPlayers)
    self.preloadCount = max(0, preloadCount)
  }

  func preload(sources: [[String: Any]]) {
    preloadedAssets.removeAll()
    guard preloadCount > 0 else {
      return
    }

    var loaded = 0
    for source in sources {
      if loaded >= preloadCount {
        break
      }
      guard let urlString = source["url"] as? String else {
        continue
      }
      guard let url = URL(string: urlString) else {
        continue
      }
      let asset = AVURLAsset(url: url)
      preloadedAssets[urlString] = asset
      asset.loadValuesAsynchronously(forKeys: ["playable", "duration"])
      loaded += 1
    }
  }

  func createController(
    controllerId: Int,
    url: String,
    autoPlay: Bool,
    looping: Bool
  ) throws {
    guard let sourceURL = URL(string: url) else {
      throw NSError(
        domain: "native_reels_player",
        code: 1001,
        userInfo: [NSLocalizedDescriptionKey: "Invalid URL for createController: \(url)"]
      )
    }

    evictToPoolSizeIfNeeded()

    let item: AVPlayerItem
    if let preloadedAsset = preloadedAssets[url] {
      item = AVPlayerItem(asset: preloadedAsset)
    } else {
      item = AVPlayerItem(url: sourceURL)
    }

    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true
    let managed = ManagedController(id: controllerId, url: url, player: player, looping: looping)
    attachObservers(to: managed, playerItem: item)

    controllers[controllerId] = managed
    creationOrder.append(controllerId)
    onState(controllerId, "preparing")
    startPositionTimerIfNeeded()

    if autoPlay {
      player.play()
    }
  }

  func play(controllerId: Int) {
    controllers[controllerId]?.player.play()
  }

  func pause(controllerId: Int) {
    controllers[controllerId]?.player.pause()
  }

  func seekTo(controllerId: Int, positionMs: Int64) {
    guard let player = controllers[controllerId]?.player else {
      return
    }
    let clampedMs = max(Int64(0), positionMs)
    let time = CMTime(value: clampedMs, timescale: 1000)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func disposeController(controllerId: Int) {
    guard let managed = controllers.removeValue(forKey: controllerId) else {
      return
    }

    creationOrder.removeAll(where: { $0 == controllerId })
    if let endObserver = managed.endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    managed.itemStatusObservation?.invalidate()
    managed.timeControlObservation?.invalidate()
    managed.player.pause()
    managed.player.replaceCurrentItem(with: nil)
    onState(controllerId, "disposed")
    stopPositionTimerIfNeeded()
  }

  func clearCache() {
    preloadedAssets.removeAll()
  }

  func setVisibleIndex(index: Int) {
    // Intentionally no-op for milestone 2.
  }

  func disposeAll() {
    let ids = Array(controllers.keys)
    for controllerId in ids {
      disposeController(controllerId: controllerId)
    }
    preloadedAssets.removeAll()
    creationOrder.removeAll()
    positionTimer?.invalidate()
    positionTimer = nil
  }

  private func evictToPoolSizeIfNeeded() {
    while controllers.count >= maxCachedPlayers {
      guard let oldest = creationOrder.first else {
        break
      }
      disposeController(controllerId: oldest)
    }
  }

  private func attachObservers(to managed: ManagedController, playerItem: AVPlayerItem) {
    managed.itemStatusObservation = playerItem.observe(
      \.status,
      options: [.new, .initial]
    ) { [weak self] item, _ in
      guard let self = self else {
        return
      }
      switch item.status {
      case .readyToPlay:
        self.onState(managed.id, "ready")
      case .failed:
        self.onState(managed.id, "error")
      case .unknown:
        self.onState(managed.id, "preparing")
      @unknown default:
        self.onState(managed.id, "error")
      }
    }

    managed.timeControlObservation = managed.player.observe(
      \.timeControlStatus,
      options: [.new, .initial]
    ) { [weak self] player, _ in
      guard let self = self else {
        return
      }
      switch player.timeControlStatus {
      case .paused:
        let state = player.currentItem?.status == .readyToPlay ? "paused" : "idle"
        self.onState(managed.id, state)
      case .waitingToPlayAtSpecifiedRate:
        self.onState(managed.id, "buffering")
      case .playing:
        self.onState(managed.id, "playing")
      @unknown default:
        self.onState(managed.id, "error")
      }
    }

    managed.endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self, weak player = managed.player] _ in
      guard let self = self else {
        return
      }
      if managed.looping {
        player?.seek(to: .zero)
        player?.play()
        self.onState(managed.id, "playing")
      } else {
        self.onState(managed.id, "completed")
      }
    }
  }

  private func startPositionTimerIfNeeded() {
    guard positionTimer == nil else {
      return
    }

    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.emitPositions()
    }
    RunLoop.main.add(timer, forMode: .common)
    positionTimer = timer
  }

  private func stopPositionTimerIfNeeded() {
    guard controllers.isEmpty else {
      return
    }
    positionTimer?.invalidate()
    positionTimer = nil
  }

  private func emitPositions() {
    for (controllerId, managed) in controllers {
      let seconds = managed.player.currentTime().seconds
      guard seconds.isFinite, seconds >= 0 else {
        continue
      }
      onPosition(controllerId, Int64(seconds * 1000))
    }
  }
}
