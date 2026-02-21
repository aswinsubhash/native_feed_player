package com.example.native_reels_player

import android.content.Context
import android.view.TextureView
import android.view.View
import io.flutter.plugin.platform.PlatformView

internal class NativeVideoPlatformView(
    context: Context,
    private val onDispose: () -> Unit
) : PlatformView {
    val textureView: TextureView = TextureView(context)

    override fun getView(): View {
        return textureView
    }

    override fun dispose() {
        onDispose()
    }
}
