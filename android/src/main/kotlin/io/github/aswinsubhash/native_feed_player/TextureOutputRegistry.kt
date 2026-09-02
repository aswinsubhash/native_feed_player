package io.github.aswinsubhash.native_feed_player

import android.view.Surface
import io.flutter.view.TextureRegistry

internal class TextureOutput(
    val id: Long,
    val surface: Surface,
    val release: () -> Unit
)

/** Maps ExoPlayer surfaces to Flutter texture entries. */
internal class TextureOutputRegistry(
    private val createOutput: () -> TextureOutput
) {
    constructor(textureRegistry: TextureRegistry) : this(
        createOutput = {
            val entry = textureRegistry.createSurfaceTexture()
            val surface = Surface(entry.surfaceTexture())
            TextureOutput(
                id = entry.id(),
                surface = surface,
                release = {
                    surface.release()
                    entry.release()
                }
            )
        }
    )

    private val outputsByController = mutableMapOf<Int, TextureOutput>()

    /** Returns the Flutter texture id bound to [controllerId]. */
    fun attach(controllerId: Int, bindSurface: (Surface) -> Unit): Long {
        outputsByController[controllerId]?.let { existing ->
            bindSurface(existing.surface)
            return existing.id
        }

        val output = createOutput()
        outputsByController[controllerId] = output
        bindSurface(output.surface)
        return output.id
    }

    fun detach(controllerId: Int, unbindSurface: (Surface) -> Unit) {
        val output = outputsByController.remove(controllerId) ?: return
        unbindSurface(output.surface)
        output.release()
    }

    fun clear(unbindSurface: (Int, Surface) -> Unit) {
        for ((controllerId, output) in outputsByController) {
            unbindSurface(controllerId, output.surface)
            output.release()
        }
        outputsByController.clear()
    }

    fun isAttached(controllerId: Int): Boolean =
        outputsByController.containsKey(controllerId)
}
