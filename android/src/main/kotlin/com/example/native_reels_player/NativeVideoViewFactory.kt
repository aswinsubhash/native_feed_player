package com.example.native_reels_player

import android.content.Context
import android.view.TextureView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

internal class NativeVideoViewFactory(
    private val textureViewPool: TextureViewPool,
    private val onCreate: (viewId: Int, view: NativeVideoPlatformView) -> Unit,
    private val onDispose: (viewId: Int, textureView: TextureView) -> Unit
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
        ) { returnedTextureView ->
            onDispose(viewId, returnedTextureView)
        }
        onCreate(viewId, view)
        return view
    }
}
