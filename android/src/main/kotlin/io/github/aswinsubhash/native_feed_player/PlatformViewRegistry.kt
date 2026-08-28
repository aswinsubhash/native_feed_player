package io.github.aswinsubhash.native_feed_player

internal class PlatformViewRegistry<Key, View : Any> {
    private val views = mutableMapOf<Key, View>()

    operator fun get(key: Key): View? = views[key]

    fun register(key: Key, view: View) {
        views[key] = view
    }

    fun removeIfCurrent(key: Key, view: View): Boolean {
        if (views[key] !== view) {
            return false
        }
        views.remove(key)
        return true
    }

    fun clear() {
        views.clear()
    }
}
