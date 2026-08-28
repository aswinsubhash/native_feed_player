package io.github.aswinsubhash.native_feed_player

import java.util.ArrayDeque

/** Buffers events until the Dart event stream attaches. */
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

    fun clearPending() {
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

/** Adapts a Pigeon event channel to [BufferedStreamHandler]. */
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

internal class VideoSizeStreamAdapter(
    private val holder: BufferedStreamHandler<VideoSizeEvent>
) : VideoSizeEventsStreamHandler() {
    override fun onListen(p0: Any?, sink: PigeonEventSink<VideoSizeEvent>) = holder.attach(sink)
    override fun onCancel(p0: Any?) = holder.detach()
}

internal class LifecycleStreamAdapter(
    private val holder: BufferedStreamHandler<ControllerLifecycleEvent>
) : LifecycleEventsStreamHandler() {
    override fun onListen(p0: Any?, sink: PigeonEventSink<ControllerLifecycleEvent>) =
        holder.attach(sink)

    override fun onCancel(p0: Any?) = holder.detach()
}
