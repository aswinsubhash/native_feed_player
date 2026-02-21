import Foundation

/// Placeholder pool abstraction for index-aware AVPlayer reuse.
final class VideoPool {
  private let maxPoolSize: Int
  private var activeControllerIds: [Int] = []

  init(maxPoolSize: Int) {
    self.maxPoolSize = maxPoolSize
  }

  func markActive(_ controllerId: Int) {
    activeControllerIds.removeAll(where: { $0 == controllerId })
    activeControllerIds.append(controllerId)
    trimToPoolSize()
  }

  func markReleased(_ controllerId: Int) {
    activeControllerIds.removeAll(where: { $0 == controllerId })
  }

  func clear() {
    activeControllerIds.removeAll()
  }

  private func trimToPoolSize() {
    if activeControllerIds.count <= maxPoolSize {
      return
    }

    activeControllerIds.removeFirst(activeControllerIds.count - maxPoolSize)
  }
}
