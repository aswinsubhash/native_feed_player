import Foundation

/// Sorted, merged half-open byte ranges.
struct ByteRangeSet: Equatable {
  private(set) var ranges: [Range<Int64>] = []

  mutating func insert(_ range: Range<Int64>) {
    guard !range.isEmpty else {
      return
    }
    var merged = range
    var result: [Range<Int64>] = []
    for existing in ranges {
      if existing.upperBound < merged.lowerBound || existing.lowerBound > merged.upperBound {
        result.append(existing)
      } else {
        merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
      }
    }
    result.append(merged)
    ranges = result.sorted { $0.lowerBound < $1.lowerBound }
  }

  /// End of the covered run containing `offset`, or nil when uncovered.
  func end(containing offset: Int64) -> Int64? {
    ranges.first { $0.contains(offset) }?.upperBound
  }

  func covers(_ length: Int64) -> Bool {
    length == 0 || ranges.first.map { $0.lowerBound == 0 && $0.upperBound >= length } == true
  }

  /// First uncovered offset below `length`, or nil when complete.
  func firstGap(below length: Int64) -> Int64? {
    var cursor: Int64 = 0
    for range in ranges {
      if range.lowerBound > cursor {
        break
      }
      cursor = max(cursor, range.upperBound)
    }
    return cursor < length ? cursor : nil
  }
}

/// Bounded in-memory byte windows for one resource.
///
/// Chunks never overlap and are kept as received, so inserting never copies
/// already retained bytes; reads return data from a single chunk.
struct MediaRangeBuffer {
  private struct Chunk {
    let offset: Int64
    let data: Data
    var end: Int64 { offset + Int64(data.count) }
  }

  private var chunks: [Chunk] = []
  private(set) var byteCount = 0

  /// Retains the parts of `data` not already held; returns bytes added.
  @discardableResult
  mutating func insert(_ data: Data, at offset: Int64) -> Int {
    guard !data.isEmpty else {
      return 0
    }
    let base = data.startIndex
    var cursor = offset
    let end = offset + Int64(data.count)
    var added = 0
    for chunk in chunks where chunk.end > cursor && chunk.offset < end {
      if chunk.offset > cursor {
        added += append(data, base: base, from: cursor - offset, to: chunk.offset - offset, at: cursor)
      }
      cursor = max(cursor, chunk.end)
    }
    if cursor < end {
      added += append(data, base: base, from: cursor - offset, to: end - offset, at: cursor)
    }
    chunks.sort { $0.offset < $1.offset }
    return added
  }

  private mutating func append(_ data: Data, base: Data.Index, from: Int64, to: Int64, at offset: Int64) -> Int {
    let slice = data.subdata(in: (base + Int(from))..<(base + Int(to)))
    chunks.append(Chunk(offset: offset, data: slice))
    byteCount += slice.count
    return slice.count
  }

  /// Bytes starting exactly at `offset`, up to `maxLength`, from one chunk.
  func read(at offset: Int64, maxLength: Int) -> Data? {
    guard maxLength > 0, let chunk = chunks.first(where: { $0.offset <= offset && offset < $0.end }) else {
      return nil
    }
    let start = chunk.data.startIndex + Int(offset - chunk.offset)
    let end = min(chunk.data.endIndex, start + maxLength)
    return chunk.data.subdata(in: start..<end)
  }

  /// Contiguous end of retained bytes from `offset`, or nil when absent.
  func contiguousEnd(from offset: Int64) -> Int64? {
    var cursor = offset
    var found = false
    for chunk in chunks where chunk.offset <= cursor && chunk.end > cursor {
      cursor = chunk.end
      found = true
    }
    return found ? cursor : nil
  }

  /// Evicts chunks until at most `limit` bytes remain, preferring chunks that
  /// hold none of `keep` and lie farthest from them. Returns bytes released.
  @discardableResult
  mutating func trim(toFit limit: Int, keeping keep: [Int64]) -> Int {
    guard byteCount > limit else {
      return 0
    }
    func distance(_ chunk: Chunk) -> Int64 {
      guard !keep.isEmpty else {
        return Int64.max
      }
      if keep.contains(where: { $0 >= chunk.offset && $0 < chunk.end }) {
        return -1
      }
      return keep.map { $0 < chunk.offset ? chunk.offset - $0 : $0 - chunk.end + 1 }.min() ?? Int64.max
    }
    var released = 0
    let victims = chunks.indices.sorted { distance(chunks[$0]) > distance(chunks[$1]) }
    var removed = Set<Int>()
    for index in victims where byteCount > limit {
      byteCount -= chunks[index].data.count
      released += chunks[index].data.count
      removed.insert(index)
    }
    chunks = chunks.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    return released
  }

  @discardableResult
  mutating func removeAll() -> Int {
    let released = byteCount
    chunks.removeAll()
    byteCount = 0
    return released
  }

  /// Every retained chunk, in offset order.
  var segments: [(offset: Int64, data: Data)] {
    chunks.map { ($0.offset, $0.data) }
  }
}
