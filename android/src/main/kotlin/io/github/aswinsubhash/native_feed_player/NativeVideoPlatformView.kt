package io.github.aswinsubhash.native_feed_player

import android.content.Context
import android.view.ViewGroup
import android.widget.FrameLayout
import android.view.TextureView
import android.view.View
import io.flutter.plugin.platform.PlatformView

internal class NativeVideoPlatformView(
    context: Context,
    val textureView: TextureView,
    private val onDispose: (TextureView) -> Unit
) : PlatformView {
    private val containerView: FrameLayout = FrameLayout(context).apply {
        addView(
            textureView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )
    }

    override fun getView(): View {
        return containerView
    }

    override fun dispose() {
        onDispose(textureView)
    }
}
