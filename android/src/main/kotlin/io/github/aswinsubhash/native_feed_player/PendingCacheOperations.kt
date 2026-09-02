package io.github.aswinsubhash.native_feed_player

/**
 * Tracks in-flight cache operations so engine detach can fail their pending
 * Pigeon replies exactly once instead of posting to a dead messenger.
 *
 * All methods are called on the main thread; worker threads never touch this
 * state directly — results are delivered from the main handler.
 */
internal class PendingCacheOperations {
    private class Pending(val onDetached: () -> Unit)

    private val lock = Any()
    private val pending = mutableMapOf<Long, Pending>()
    private var seed = 0L
    private var detached = false

    fun attach() {
        synchronized(lock) {
            // Detach already failed every pending reply; a re-attach must not
            // crash on leftovers from a worker that raced the detach.
            pending.clear()
            detached = false
        }
    }

    /**
     * Reserves a delivery token for a new operation. [onDetached] runs exactly
     * once if the engine detaches before the operation completes. Returns null
     * when the engine is already detached and no new work should start.
     */
    fun register(onDetached: () -> Unit): Long? {
        synchronized(lock) {
            if (detached) {
                return null
            }
            seed += 1
            pending[seed] = Pending(onDetached)
            return seed
        }
    }

    /**
     * Marks [token] as delivered by its owner. Returns false when detach
     * already consumed the token, in which case the caller must not deliver.
     */
    fun complete(token: Long): Boolean {
        synchronized(lock) {
            return pending.remove(token) != null
        }
    }

    /**
     * Fails every pending operation through its registered [Pending.onDetached]
     * action and rejects new work. Each action runs exactly once; later
     * [complete] calls for those tokens return false.
     *
     * @return the number of operations that had not completed yet.
     */
    fun detach(): Int {
        val actions: List<() -> Unit>
        synchronized(lock) {
            detached = true
            actions = pending.values.map { it.onDetached }
            pending.clear()
        }
        for (action in actions) {
            action()
        }
        return actions.size
    }

    fun isDetached(): Boolean {
        synchronized(lock) {
            return detached
        }
    }
}
