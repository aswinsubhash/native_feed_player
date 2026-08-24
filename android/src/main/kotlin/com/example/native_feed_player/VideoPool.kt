package com.example.native_feed_player

/**
 * Placeholder pool abstraction for mapping feed index -> player instances.
 */
internal class VideoPool(
    private val maxPoolSize: Int
) {
    private val activeControllerIds = linkedSetOf<Int>()

    fun markActive(controllerId: Int) {
        activeControllerIds.add(controllerId)
        trimToPoolSize()
    }

    fun markReleased(controllerId: Int) {
        activeControllerIds.remove(controllerId)
    }

    fun clear() {
        activeControllerIds.clear()
    }

    private fun trimToPoolSize() {
        while (activeControllerIds.size > maxPoolSize) {
            val oldest = activeControllerIds.firstOrNull() ?: return
            activeControllerIds.remove(oldest)
        }
    }
}
