import Foundation

/// A source the feed can play, addressed by a caller-owned stable id.
struct RegisteredSource {
  let id: String
  let uri: String
  let rank: Int
  let kind: FeedMediaKindMessage
  let headers: [String: String]
}

/// Ordered set of feed sources plus the window arithmetic over them.
///
/// Sources are keyed by id rather than list position, so appending a page
/// cannot renumber existing entries or invalidate the preload window. Rank is
/// only an ordering hint used to compute distance from the viewport.
/// Which way the viewport is travelling through the feed.
enum ScrollDirection {
  case unknown
  case forward
  case backward
}

final class FeedSourceRegistry {
  private var sourcesById: [String: RegisteredSource] = [:]

  private(set) var visibleSourceId: String?

  /// Inferred from successive viewport updates. Feeds are overwhelmingly
  /// consumed in one direction, so the preload budget should follow travel
  /// rather than spend half of itself behind the user.
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
    if visibleSourceId == nil {
      visibleSourceId = lowestRankedId()
    }
  }

  func remove(ids: [String]) {
    for id in ids {
      sourcesById.removeValue(forKey: id)
    }
    if let visibleSourceId, sourcesById[visibleSourceId] == nil {
      self.visibleSourceId = lowestRankedId()
      direction = .unknown
    }
  }

  func clear() {
    sourcesById.removeAll()
    visibleSourceId = nil
    direction = .unknown
  }

  func setVisible(_ sourceId: String) {
    guard let target = sourcesById[sourceId] else {
      return
    }
    let previousRank = visibleRank()
    visibleSourceId = sourceId
    guard let previousRank else {
      direction = .unknown
      return
    }
    if target.rank > previousRank {
      direction = .forward
    } else if target.rank < previousRank {
      direction = .backward
    }
    // Re-selecting the same position tells us nothing new.
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
    return abs(rank - visible)
  }

  /// Sources that should be prepared, nearest first.
  ///
  /// `ahead` and `behind` are expressed relative to travel, not to rank: when
  /// the user scrolls backwards they are swapped so the budget still lands in
  /// front of the viewport.
  ///
  /// `scale` shrinks the window under sustained stress; 1.0 is the configured
  /// size. Sources sharing a URI are collapsed to the nearest one so a feed
  /// that repeats a clip does not prepare it twice.
  func preloadWindow(ahead: Int, behind: Int, scale: Double = 1.0) -> [RegisteredSource] {
    guard let visible = visibleRank() else {
      return []
    }

    let forwardBudget = direction == .backward ? behind : ahead
    let backwardBudget = direction == .backward ? ahead : behind
    let scaledForward = scaleBudget(forwardBudget, scale)
    let scaledBackward = scaleBudget(backwardBudget, scale)

    var seenUris = Set<String>()
    return sourcesById.values
      .filter { source in
        let delta = source.rank - visible
        return delta >= -scaledBackward && delta <= scaledForward
      }
      .sorted { lhs, rhs in
        let lhsDistance = abs(lhs.rank - visible)
        let rhsDistance = abs(rhs.rank - visible)
        // Rank breaks ties so ordering is deterministic across dictionary
        // iteration order.
        return lhsDistance == rhsDistance
          ? lhs.rank < rhs.rank
          : lhsDistance < rhsDistance
      }
      .filter { source in seenUris.insert(source.uri).inserted }
  }

  /// Keeps at least the visible item in the window while scaling down.
  private func scaleBudget(_ budget: Int, _ scale: Double) -> Int {
    guard budget > 0 else {
      return 0
    }
    return max(0, Int((Double(budget) * scale).rounded()))
  }

  private func lowestRankedId() -> String? {
    sourcesById.values.min(by: { $0.rank < $1.rank })?.id
  }
}
