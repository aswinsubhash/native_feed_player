final class PlatformViewRegistry<Key: Hashable, View: AnyObject> {
  private var views: [Key: View] = [:]

  subscript(key: Key) -> View? {
    views[key]
  }

  func register(_ view: View, for key: Key) {
    views[key] = view
  }

  func removeIfCurrent(_ view: View, for key: Key) -> Bool {
    guard views[key] === view else {
      return false
    }
    views.removeValue(forKey: key)
    return true
  }

  func removeAll() {
    views.removeAll()
  }
}
