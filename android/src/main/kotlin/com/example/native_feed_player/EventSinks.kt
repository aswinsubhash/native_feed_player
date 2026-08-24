package com.example.native_feed_player

import java.util.ArrayDeque

/**
 * Holds the Pigeon sink for one event channel and buffers events emitted
 * before Dart subscribes.
 *
 * Native playback starts reporting state during `createController`, which runs
 * before the caller has had a chance to listen to that controller's stream, so
 * without a small buffer the first transition is silently lost.
 */
internal class BufferedStreamHandler<T>(private val maxBuffered: Int = 64) {
    private val pending = ArrayDeque<T>()
    private var sink: PigeonEventSink<T>? = null

    fun attach(sink: PigeonEventSink<T>) {
        this.sink = sink
        while (pending.isNotEmpty()) {
            sink.success(pending.removeFirst())
        }
    }

    fun detach() {
        sink = null
        pending.clear()
    }

    fun emit(event: T) {
        val target = sink
        if (target != null) {
            target.success(event)
            return
        }
        if (pending.size >= maxBuffered) {
            pending.removeFirst()
        }
        pending.addLast(event)
    }
}

/**
 * Pigeon generates a distinct abstract handler per event channel, so each one
 * needs a concrete adapter that forwards its sink into a shared holder.
 */
internal class PlaybackStateStreamAdapter(
    private val holder: BufferedStreamHandler<PlaybackStateEvent>
) : PlaybackStateEventsStreamHandler() {
    override fun onListen(p0: Any?, sink: PigeonEventSink<PlaybackStateEvent>) = holder.attach(sink)
    override fun onCancel(p0: Any?) = holder.detach()
}

internal class PositionStreamAdapter(
    private val holder: BufferedStreamHandler<PositionEvent>
) : PositionEventsStreamHandler() {
    override fun onListen(p0: Any?, sink: PigeonEventSink<PositionEvent>) = holder.attach(sink)
    override fun onCancel(p0: Any?) = holder.detach()
}

internal class MetricsStreamAdapter(
    private val holder: BufferedStreamHandler<MetricsEvent>
) : MetricsEventsStreamHandler() {
    override fun onListen(p0: Any?, sink: PigeonEventSink<MetricsEvent>) = holder.attach(sink)
    override fun onCancel(p0: Any?) = holder.detach()
}

internal class LifecycleStreamAdapter(
    private val holder: BufferedStreamHandler<ControllerLifecycleEvent>
) : LifecycleEventsStreamHandler() {
    override fun onListen(p0: Any?, sink: PigeonEventSink<ControllerLifecycleEvent>) =
        holder.attach(sink)

    override fun onCancel(p0: Any?) = holder.detach()
}
