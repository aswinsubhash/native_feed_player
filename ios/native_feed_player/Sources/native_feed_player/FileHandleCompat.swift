import Foundation

/// `FileHandle` wrappers with iOS 13.0 through 13.3 fallbacks.
extension FileHandle {
  func readCompat(upToCount count: Int) throws -> Data? {
    guard count > 0 else {
      return Data()
    }
    if #available(iOS 13.4, *) {
      return try read(upToCount: count)
    }
    return readData(ofLength: count)
  }

  func seekToEndCompat() throws {
    if #available(iOS 13.4, *) {
      try seekToEnd()
      return
    }
    seekToEndOfFile()
  }

  func seekCompat(toOffset offset: UInt64) throws {
    if #available(iOS 13.4, *) {
      try seek(toOffset: offset)
      return
    }
    seek(toFileOffset: offset)
  }

  func writeCompat(contentsOf data: Data) throws {
    if #available(iOS 13.4, *) {
      try write(contentsOf: data)
      return
    }
    write(data)
  }

  func closeCompat() throws {
    if #available(iOS 13.4, *) {
      try close()
      return
    }
    closeFile()
  }
}
