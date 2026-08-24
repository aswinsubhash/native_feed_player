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
final class FeedSourceRegistry {
  private var sourcesById: [String: RegisteredSource] = [:]

  private(set) var visibleSourceId: String?

  var count: Int { sourcesById.count }

  func replaceAll(_ sources: [RegisteredSource]) {
    sourcesById.removeAll()
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
    }
  }

  func clear() {
    sourcesById.removeAll()
    visibleSourceId = nil
  }

  func setVisible(_ sourceId: String) {
    guard sourcesById[sourceId] != nil else {
      return
    }
    visibleSourceId = sourceId
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
  /// The window is asymmetric because feeds travel forward: `ahead` positions
  /// past the viewport are worth more than `behind` positions already seen.
  func preloadWindow(ahead: Int, behind: Int) -> [RegisteredSource] {
    guard let visible = visibleRank() else {
      return []
    }
    return sourcesById.values
      .filter { source in
        let delta = source.rank - visible
        return delta >= -behind && delta <= ahead
      }
      .sorted { abs($0.rank - visible) < abs($1.rank - visible) }
  }

  private func lowestRankedId() -> String? {
    sourcesById.values.min(by: { $0.rank < $1.rank })?.id
  }
}
