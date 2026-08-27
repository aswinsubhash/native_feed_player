package io.github.aswinsubhash.native_feed_player

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

internal class NativeVideoViewFactory(
    private val textureViewPool: TextureViewPool,
    private val onCreate: (viewId: Int, view: NativeVideoPlatformView) -> Unit,
    private val onDispose: (viewId: Int, view: NativeVideoPlatformView) -> Unit
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(
        context: Context,
        viewId: Int,
        args: Any?
    ): PlatformView {
        val textureView = textureViewPool.acquire(context)
        val view = NativeVideoPlatformView(
            context = context,
            textureView = textureView
        ) { disposedView ->
            onDispose(viewId, disposedView)
        }
        onCreate(viewId, view)
        return view
    }
}
