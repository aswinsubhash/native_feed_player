package io.github.aswinsubhash.native_feed_player

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner

/**
 * Bridges process foreground state to playback.
 *
 * Process lifecycle covers activities started before the engine attached and
 * debounces configuration changes, which per-activity counting cannot.
 */
internal class AppForegroundObserver(
    private val lifecycle: Lifecycle,
    private val onForeground: () -> Unit,
    private val onBackground: () -> Unit
) : LifecycleEventObserver {
    private var attached = false

    fun attach() {
        if (attached) {
            return
        }
        attached = true
        // addObserver replays ON_START when already foregrounded. A CREATED
        // process has no started activity, so sync the background state now.
        // INITIALIZED means the process lifecycle is not running at all (its
        // startup initializer was removed); assume foreground rather than
        // never playing.
        if (lifecycle.currentState == Lifecycle.State.CREATED) {
            onBackground()
        }
        lifecycle.addObserver(this)
    }

    fun detach() {
        if (!attached) {
            return
        }
        attached = false
        lifecycle.removeObserver(this)
    }

    override fun onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) {
        when (event) {
            Lifecycle.Event.ON_START -> onForeground()
            Lifecycle.Event.ON_STOP -> onBackground()
            else -> Unit
        }
    }
}
