import Foundation

/// Deployment-target-safe FileHandle helpers.
///
/// The throwing FileHandle API landed in iOS 13.4, but Flutter's podhelper
/// pins every pod target to the Flutter minimum (13.0), so the plugin cannot
/// simply raise its own floor. These wrappers use the throwing API where it
/// exists and fall back to the legacy calls below it.
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
