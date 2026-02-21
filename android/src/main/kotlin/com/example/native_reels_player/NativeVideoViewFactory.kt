package com.example.native_reels_player

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

internal class NativeVideoViewFactory(
    private val onCreate: (viewId: Int, view: NativeVideoPlatformView) -> Unit,
    private val onDispose: (viewId: Int) -> Unit
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(
        context: Context,
        viewId: Int,
        args: Any?
    ): PlatformView {
        val view = NativeVideoPlatformView(context = context) {
            onDispose(viewId)
        }
        onCreate(viewId, view)
        return view
    }
}
