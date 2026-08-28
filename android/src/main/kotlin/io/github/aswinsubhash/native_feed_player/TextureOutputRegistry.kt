package io.github.aswinsubhash.native_feed_player

import android.view.Surface
import io.flutter.view.TextureRegistry

/** Maps ExoPlayer surfaces to Flutter texture entries. */
internal class TextureOutputRegistry(
    private val textureRegistry: TextureRegistry
) {
    private class TextureOutput(
        val entry: TextureRegistry.SurfaceTextureEntry,
        val surface: Surface
    )

    private val outputsByController = mutableMapOf<Int, TextureOutput>()

    /** Returns the Flutter texture id bound to [controllerId]. */
    fun attach(controllerId: Int, bindSurface: (Surface) -> Unit): Long {
        outputsByController[controllerId]?.let { existing ->
            bindSurface(existing.surface)
            return existing.entry.id()
        }

        val entry = textureRegistry.createSurfaceTexture()
        val surface = Surface(entry.surfaceTexture())
        outputsByController[controllerId] = TextureOutput(entry = entry, surface = surface)
        bindSurface(surface)
        return entry.id()
    }

    fun detach(controllerId: Int, unbindSurface: (Surface) -> Unit) {
        val output = outputsByController.remove(controllerId) ?: return
        unbindSurface(output.surface)
        output.surface.release()
        output.entry.release()
    }

    fun clear(unbindSurface: (Int, Surface) -> Unit) {
        for ((controllerId, output) in outputsByController) {
            unbindSurface(controllerId, output.surface)
            output.surface.release()
            output.entry.release()
        }
        outputsByController.clear()
    }

    fun isAttached(controllerId: Int): Boolean =
        outputsByController.containsKey(controllerId)
}
