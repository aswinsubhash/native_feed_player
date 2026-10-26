import Foundation

/// Process-wide admission for streaming work shared by every engine.
///
/// Bounds the bytes the loaders retain in memory and the number of concurrent
/// network transfers. OS networking and decoder memory are outside this count.
final class MediaTransferBudget {
  struct Limits {
    /// Largest single `respond(with:)` delivery.
    var chunkSize = 512 * 1024
    /// Largest byte range requested per HTTP request.
    var fetchSize = 1024 * 1024
    /// Bytes one resource may retain in memory.
    var perResourceBytes = 2 * 1024 * 1024
    /// Bytes all resources together may retain in memory.
    var totalBufferBytes = 16 * 1024 * 1024
    /// Concurrent network transfers across all resources.
    var maxActiveTransfers = 4
  }

  static let shared = MediaTransferBudget(limits: Limits())

  let limits: Limits
  private let lock = NSLock()
  private var retained = 0
  private var active = 0
  private var peakRetained = 0
  private var waiters: [(id: UUID, queue: DispatchQueue, wake: () -> Void)] = []

  init(limits: Limits) {
    self.limits = limits
  }

  func reserveMemory(_ bytes: Int) -> Bool {
    lock.withLock {
      guard bytes >= 0, retained + bytes <= limits.totalBufferBytes else {
        return false
      }
      retained += bytes
      peakRetained = max(peakRetained, retained)
      return true
    }
  }

  func releaseMemory(_ bytes: Int) {
    guard bytes > 0 else {
      return
    }
    lock.withLock { retained = max(0, retained - bytes) }
  }

  func acquireTransfer() -> Bool {
    lock.withLock {
      guard active < limits.maxActiveTransfers else {
        return false
      }
      active += 1
      return true
    }
  }

  /// Frees a transfer slot and wakes the longest-waiting request, if any.
  func releaseTransfer() {
    let waiter: (id: UUID, queue: DispatchQueue, wake: () -> Void)? = lock.withLock {
      active = max(0, active - 1)
      return waiters.isEmpty ? nil : waiters.removeFirst()
    }
    if let waiter {
      waiter.queue.async(execute: waiter.wake)
    }
  }

  func enqueueWaiter(id: UUID, queue: DispatchQueue, wake: @escaping () -> Void) {
    lock.withLock {
      if !waiters.contains(where: { $0.id == id }) {
        waiters.append((id, queue, wake))
      }
    }
  }

  func removeWaiter(id: UUID) {
    lock.withLock { waiters.removeAll { $0.id == id } }
  }

  var retainedBytes: Int { lock.withLock { retained } }
  var peakRetainedBytes: Int { lock.withLock { peakRetained } }
  var activeTransfers: Int { lock.withLock { active } }
}
