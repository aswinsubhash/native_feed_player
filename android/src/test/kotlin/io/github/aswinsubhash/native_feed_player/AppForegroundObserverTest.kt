package io.github.aswinsubhash.native_feed_player

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import kotlin.test.Test
import kotlin.test.assertEquals

internal class AppForegroundObserverTest {
    private class Owner : LifecycleOwner {
        val registry = LifecycleRegistry.createUnsafe(this)
        override val lifecycle: Lifecycle get() = registry
    }

    private val events = mutableListOf<String>()
    private val owner = Owner()

    private fun observer() = AppForegroundObserver(
        lifecycle = owner.lifecycle,
        onForeground = { events += "foreground" },
        onBackground = { events += "background" }
    )

    @Test
    fun attachAfterActivityAlreadyStarted_syncsForegroundOnce() {
        owner.registry.currentState = Lifecycle.State.RESUMED

        observer().attach()

        assertEquals(listOf("foreground"), events)
    }

    @Test
    fun attachWhileProcessHasNoStartedActivity_startsBackgrounded() {
        owner.registry.currentState = Lifecycle.State.CREATED
        val observer = observer()

        observer.attach()
        owner.registry.currentState = Lifecycle.State.RESUMED

        assertEquals(listOf("background", "foreground"), events)
    }

    @Test
    fun uninitializedProcessLifecycle_isNotTreatedAsBackground() {
        observer().attach()

        assertEquals(emptyList(), events)
    }

    @Test
    fun foregroundTransitionsAreReportedOncePerChange() {
        owner.registry.currentState = Lifecycle.State.RESUMED
        val observer = observer()
        observer.attach()

        // Activity churn inside the foreground (another activity resuming,
        // a configuration change) only moves between STARTED and RESUMED.
        owner.registry.currentState = Lifecycle.State.STARTED
        owner.registry.currentState = Lifecycle.State.RESUMED
        owner.registry.currentState = Lifecycle.State.CREATED
        owner.registry.currentState = Lifecycle.State.RESUMED

        assertEquals(listOf("foreground", "background", "foreground"), events)
    }

    @Test
    fun detach_stopsDelivery_andIsIdempotent() {
        owner.registry.currentState = Lifecycle.State.RESUMED
        val observer = observer()
        observer.attach()
        observer.attach()
        observer.detach()
        observer.detach()

        owner.registry.currentState = Lifecycle.State.CREATED

        assertEquals(listOf("foreground"), events)
        assertEquals(0, owner.registry.observerCount)
    }
}
