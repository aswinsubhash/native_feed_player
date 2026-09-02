package io.github.aswinsubhash.native_feed_player

import android.content.Context
import android.view.TextureView
import android.view.ViewGroup
import java.util.ArrayDeque

internal class TextureViewPool(
    private val maxPoolSize: Int
) {
    private val pooledViews = ArrayDeque<TextureView>()

    fun acquire(context: Context): TextureView {
        val view = if (pooledViews.isEmpty()) {
            TextureView(context)
        } else {
            pooledViews.removeFirst()
        }
        detachFromParent(view)
        return view
    }

    fun release(textureView: TextureView) {
        detachFromParent(textureView)
        // ExoPlayer installs an internal surface listener while attached;
        // clearing it keeps a recycled view from talking to a dead player.
        textureView.surfaceTextureListener = null
        if (pooledViews.size < maxPoolSize) {
            pooledViews.addLast(textureView)
        }
    }

    fun clear() {
        pooledViews.clear()
    }

    private fun detachFromParent(view: TextureView) {
        val parent = view.parent as? ViewGroup ?: return
        parent.removeView(view)
    }
}
