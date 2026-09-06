import Foundation

/// A source the feed can play, addressed by a caller-owned stable id.
struct RegisteredSource {
  let id: String
  let uri: String
  let rank: Int
  let kind: FeedMediaKindMessage
  let headers: [String: String]
  /// Optional stable cache identity replacing `uri` in cache keys.
  var cacheKey: String? = nil

  var cacheIdentity: String {
    MediaCacheIdentity.make(uri: uri, headers: headers, cacheKey: cacheKey)
  }

  var resourceIdentity: String {
    cacheIdentity + MediaCacheIdentity.make(uri: uri, headers: headers)
  }

  var playbackIdentity: String {
    let rawHeaders = headers.sorted { $0.key < $1.key }.map { name, value in
      "\(name.utf8.count):\(name)\(value.utf8.count):\(value)"
    }.joined()
    let key = cacheKey.map { "\($0.utf8.count):\($0)" } ?? "null"
    let material = [uri, String(describing: kind), key, rawHeaders].map {
      "\($0.utf8.count):\($0)"
    }.joined()
    return MediaCacheIdentity.make(uri: material, headers: [:])
  }
}

/// Ordered sources keyed by stable ID with preload-window operations.
/// Which way the viewport is travelling through the feed.
enum ScrollDirection {
  case unknown
  case forward
  case backward
}

final class FeedSourceRegistry {
  private var sourcesById: [String: RegisteredSource] = [:]
  private var idsByRank: [Int: [String]] = [:]
  private var sortedRanks: [Int] = []

  private(set) var visibleSourceId: String?

  /// Inferred direction used to bias the preload window.
  private(set) var direction: ScrollDirection = .unknown

  var count: Int { sourcesById.count }

  func replaceAll(_ sources: [RegisteredSource]) {
    sourcesById.removeAll()
    direction = .unknown
    append(sources)
    if let visibleSourceId, sourcesById[visibleSourceId] == nil {
      self.visibleSourceId = lowestRankedId()
    }
  }

  func append(_ sources: [RegisteredSource]) {
    for source in sources where !source.uri.isEmpty {
      sourcesById[source.id] = source
    }
    rebuildRankIndex()
    if visibleSourceId == nil {
      visibleSourceId = lowestRankedId()
    }
  }

  func remove(ids: [String]) {
    for id in ids {
      sourcesById.removeValue(forKey: id)
    }
    rebuildRankIndex()
    if let visibleSourceId, sourcesById[visibleSourceId] == nil {
      self.visibleSourceId = lowestRankedId()
      direction = .unknown
    }
  }

  func clear() {
    sourcesById.removeAll()
    idsByRank.removeAll()
    sortedRanks.removeAll()
    visibleSourceId = nil
    direction = .unknown
  }

  @discardableResult
  func setVisible(_ sourceId: String) -> Bool {
    guard let target = sourcesById[sourceId] else {
      return false
    }
    let previousRank = visibleRank()
    visibleSourceId = sourceId
    guard let previousRank else {
      direction = .unknown
      return true
    }
    if target.rank > previousRank {
      direction = .forward
    } else if target.rank < previousRank {
      direction = .backward
    }
    // Preserve direction when the rank is unchanged.
    return true
  }

  func source(id: String) -> RegisteredSource? {
    sourcesById[id]
  }

  func visibleRank() -> Int? {
    guard let visibleSourceId else {
      return nil
    }
    return sourcesById[visibleSourceId]?.rank
  }

  /// Distance in feed positions from the visible source, or nil if unknown.
  func distanceFromVisible(id: String) -> Int? {
    guard let rank = sourcesById[id]?.rank, let visible = visibleRank() else {
      return nil
    }
    return distance(rank, visible)
  }

  /// Returns the nearest unique sources in the travel-relative preload window.
  /// `scale` applies runtime window degradation.
  func preloadWindow(ahead: Int, behind: Int, scale: Double = 1.0) -> [RegisteredSource] {
    guard let visible = visibleRank() else {
      return []
    }

    let forwardBudget = direction == .backward ? behind : ahead
    let backwardBudget = direction == .backward ? ahead : behind
    let scaledForward = scaleBudget(forwardBudget, scale)
    let scaledBackward = scaleBudget(backwardBudget, scale)

    let lower = visible.subtractingReportingOverflow(scaledBackward)
    let upper = visible.addingReportingOverflow(scaledForward)
    let minimum = lower.overflow ? Int.min : lower.partialValue
    let maximum = upper.overflow ? Int.max : upper.partialValue
    var index = lowerBound(minimum)
    var candidates: [RegisteredSource] = []
    while index < sortedRanks.count, sortedRanks[index] <= maximum {
      candidates.append(contentsOf: (idsByRank[sortedRanks[index]] ?? []).compactMap {
        sourcesById[$0]
      })
      index += 1
    }
    var seenIdentities = Set<String>()
    return candidates
      .sorted { lhs, rhs in
        let lhsDistance = distance(lhs.rank, visible)
        let rhsDistance = distance(rhs.rank, visible)
        // Use rank as a deterministic tie-breaker.
        if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.id == visibleSourceId { return rhs.id != visibleSourceId }
        if rhs.id == visibleSourceId { return false }
        return lhs.id < rhs.id
      }
      .filter { source in seenIdentities.insert(source.cacheIdentity).inserted }
  }

  /// Keeps at least the visible item in the window while scaling down.
  private func scaleBudget(_ budget: Int, _ scale: Double) -> Int {
    guard budget > 0 else {
      return 0
    }
    return max(0, Int((Double(budget) * scale).rounded()))
  }

  private func lowestRankedId() -> String? {
    sortedRanks.first.flatMap { idsByRank[$0]?.first }
  }

  private func rebuildRankIndex() {
    idsByRank.removeAll(keepingCapacity: true)
    for source in sourcesById.values {
      idsByRank[source.rank, default: []].append(source.id)
    }
    sortedRanks = idsByRank.keys.sorted()
    for rank in sortedRanks {
      idsByRank[rank]?.sort()
    }
  }

  private func lowerBound(_ rank: Int) -> Int {
    var low = 0
    var high = sortedRanks.count
    while low < high {
      let middle = low + (high - low) / 2
      if sortedRanks[middle] < rank {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return low
  }

  private func distance(_ first: Int, _ second: Int) -> Int {
    let delta = max(first, second).subtractingReportingOverflow(min(first, second))
    return delta.overflow ? Int.max : delta.partialValue
  }
}
