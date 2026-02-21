import AVFoundation
import Foundation

/// AVPlayer lifecycle and event orchestration for native reels playback.
final class AVPlayerManager {
  typealias StateCallback = (_ controllerId: Int, _ state: String) -> Void
  typealias PositionCallback = (_ controllerId: Int, _ positionMs: Int64) -> Void

  private struct PreloadedAsset {
    let url: String
    let asset: AVURLAsset
  }

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
  private var sourcesByIndex: [Int: String] = [:]
  private var preloadedAssets: [Int: PreloadedAsset] = [:]
  private var maxCachedPlayers: Int = 5
  private var preloadCount: Int = 2
  private var visibleIndex: Int = 0
  private var preloadGeneration: Int = 0
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
    schedulePreloadWindow()
  }

  func preload(sources: [[String: Any]]) {
    sourcesByIndex.removeAll()
    for source in sources {
      guard let index = source["index"] as? Int else {
        continue
      }
      guard let url = source["url"] as? String, !url.isEmpty else {
        continue
      }
      sourcesByIndex[index] = url
    }

    if !sourcesByIndex.isEmpty, sourcesByIndex[visibleIndex] == nil {
      visibleIndex = sourcesByIndex.keys.min() ?? 0
    }

    schedulePreloadWindow()
  }

  func createController(
    controllerId: Int,
    url: String,
    index: Int,
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
    if let preloaded = preloadedAssets[index], preloaded.url == url {
      item = AVPlayerItem(asset: preloaded.asset)
      preloadedAssets.removeValue(forKey: index)
    } else {
      preloadedAssets.removeValue(forKey: index)
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

    schedulePreloadWindow()
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
    schedulePreloadWindow()
  }

  func clearCache() {
    preloadGeneration += 1
    sourcesByIndex.removeAll()
    preloadedAssets.removeAll()
  }

  func setVisibleIndex(index: Int) {
    visibleIndex = index
    schedulePreloadWindow()
  }

  func disposeAll() {
    preloadGeneration += 1
    let ids = Array(controllers.keys)
    for controllerId in ids {
      disposeController(controllerId: controllerId)
    }
    sourcesByIndex.removeAll()
    preloadedAssets.removeAll()
    creationOrder.removeAll()
    positionTimer?.invalidate()
    positionTimer = nil
  }

  private func schedulePreloadWindow() {
    preloadGeneration += 1
    let generation = preloadGeneration
    let targetIndices = preloadWindowIndices()

    let stale = preloadedAssets.keys.filter { !targetIndices.contains($0) }
    for index in stale {
      preloadedAssets.removeValue(forKey: index)
    }

    for index in targetIndices.sorted() {
      guard let urlString = sourcesByIndex[index], let url = URL(string: urlString) else {
        continue
      }

      if let existing = preloadedAssets[index], existing.url == urlString {
        continue
      }

      let asset = AVURLAsset(url: url)
      let keys = ["playable", "duration"]

      asset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
        DispatchQueue.main.async {
          guard let self else {
            return
          }
          guard generation == self.preloadGeneration else {
            return
          }
          guard self.sourcesByIndex[index] == urlString else {
            self.preloadedAssets.removeValue(forKey: index)
            return
          }

          var playableError: NSError?
          let playableStatus = asset.statusOfValue(
            forKey: "playable",
            error: &playableError
          )

          if playableStatus == .loaded || playableStatus == .unknown {
            self.preloadedAssets[index] = PreloadedAsset(url: urlString, asset: asset)
          } else {
            self.preloadedAssets.removeValue(forKey: index)
          }
        }
      }
    }
  }

  private func preloadWindowIndices() -> Set<Int> {
    guard preloadCount > 0, !sourcesByIndex.isEmpty else {
      return []
    }

    guard let minIndex = sourcesByIndex.keys.min(),
      let maxIndex = sourcesByIndex.keys.max()
    else {
      return []
    }

    let start = max(minIndex, visibleIndex - preloadCount)
    let end = min(maxIndex, visibleIndex + preloadCount)
    if start > end {
      return []
    }
    return Set(start...end)
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
