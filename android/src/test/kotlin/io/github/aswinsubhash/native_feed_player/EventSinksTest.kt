package io.github.aswinsubhash.native_feed_player

import io.flutter.plugin.common.EventChannel
import kotlin.test.Test
import kotlin.test.assertEquals

internal class EventSinksTest {
    @Test
    fun replacementSessionDropsBufferedEvents() {
        val holder = BufferedStreamHandler<String>()
        val sink = RecordingEventSink()

        holder.emit("old")
        holder.clearPending()
        holder.attach(PigeonEventSink(sink))
        holder.emit("new")

        assertEquals(listOf<Any?>("new"), sink.events)
    }

    @Test
    fun replacementListenerReceivesNewEvents() {
        val holder = BufferedStreamHandler<String>()
        val oldSink = RecordingEventSink()
        val newSink = RecordingEventSink()

        holder.attach(PigeonEventSink(oldSink))
        holder.detach()
        holder.attach(PigeonEventSink(newSink))
        holder.emit("new")

        assertEquals(emptyList<Any?>(), oldSink.events)
        assertEquals(listOf<Any?>("new"), newSink.events)
    }

    private class RecordingEventSink : EventChannel.EventSink {
        val events = mutableListOf<Any?>()

        override fun success(event: Any?) {
            events += event
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = Unit

        override fun endOfStream() = Unit
    }
}
