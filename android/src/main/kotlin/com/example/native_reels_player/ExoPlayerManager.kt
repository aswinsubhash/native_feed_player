package com.example.native_reels_player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import java.util.ArrayDeque

internal class ExoPlayerManager(
    context: Context,
    private val onState: (controllerId: Int, state: String) -> Unit,
    private val onPosition: (controllerId: Int, positionMs: Long) -> Unit
) {
    private data class ManagedPlayer(
        val player: ExoPlayer,
        val listener: Player.Listener
    )

    private val appContext = context.applicationContext
    private val managedPlayers = mutableMapOf<Int, ManagedPlayer>()
    private val creationOrder = ArrayDeque<Int>()
    private val preloadedMediaItems = mutableMapOf<String, MediaItem>()
    private val handler = Handler(Looper.getMainLooper())

    private var maxCachedPlayers = 5
    private var preloadCount = 2
    private var tickerRunning = false

    private val positionTicker = object : Runnable {
        override fun run() {
            emitPositions()
            if (managedPlayers.isNotEmpty()) {
                handler.postDelayed(this, POSITION_TICK_MS)
            } else {
                tickerRunning = false
            }
        }
    }

    fun initialize(maxCachedPlayers: Int, preloadCount: Int) {
        this.maxCachedPlayers = maxOf(1, maxCachedPlayers)
        this.preloadCount = maxOf(0, preloadCount)
    }

    fun preload(sources: List<Map<*, *>>) {
        preloadedMediaItems.clear()
        if (preloadCount == 0) {
            return
        }

        var loaded = 0
        for (source in sources) {
            if (loaded >= preloadCount) {
                break
            }
            val url = source["url"] as? String ?: continue
            val uri = Uri.parse(url)
            preloadedMediaItems[url] = MediaItem.fromUri(uri)
            loaded += 1
        }
    }

    fun createController(
        controllerId: Int,
        url: String,
        autoPlay: Boolean,
        looping: Boolean
    ) {
        evictToPoolSizeIfNeeded()

        val player = ExoPlayer.Builder(appContext).build()
        val listener = playerListener(controllerId, player)
        player.addListener(listener)
        player.repeatMode = if (looping) {
            Player.REPEAT_MODE_ONE
        } else {
            Player.REPEAT_MODE_OFF
        }

        val mediaItem = preloadedMediaItems[url] ?: MediaItem.fromUri(Uri.parse(url))
        player.setMediaItem(mediaItem)
        onState(controllerId, "preparing")
        player.prepare()
        if (autoPlay) {
            player.playWhenReady = true
        }

        managedPlayers[controllerId] = ManagedPlayer(player = player, listener = listener)
        creationOrder.addLast(controllerId)
        startTickerIfNeeded()
    }

    fun play(controllerId: Int) {
        managedPlayers[controllerId]?.player?.play()
    }

    fun pause(controllerId: Int) {
        managedPlayers[controllerId]?.player?.pause()
    }

    fun seekTo(controllerId: Int, positionMs: Long) {
        managedPlayers[controllerId]?.player?.seekTo(positionMs.coerceAtLeast(0L))
    }

    fun disposeController(controllerId: Int) {
        releaseController(controllerId = controllerId, emitDisposed = true)
    }

    fun clearCache() {
        preloadedMediaItems.clear()
    }

    fun setVisibleIndex(index: Int) {
        // Intentionally no-op for milestone 2.
    }

    fun disposeAll() {
        val ids = managedPlayers.keys.toList()
        for (id in ids) {
            releaseController(controllerId = id, emitDisposed = true)
        }
        preloadedMediaItems.clear()
        creationOrder.clear()
        handler.removeCallbacks(positionTicker)
        tickerRunning = false
    }

    private fun evictToPoolSizeIfNeeded() {
        while (managedPlayers.size >= maxCachedPlayers) {
            if (creationOrder.isEmpty()) {
                break
            }
            val oldestControllerId = creationOrder.removeFirst()
            releaseController(controllerId = oldestControllerId, emitDisposed = true)
        }
    }

    private fun playerListener(controllerId: Int, player: ExoPlayer): Player.Listener {
        return object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_IDLE -> onState(controllerId, "idle")
                    Player.STATE_BUFFERING -> onState(controllerId, "buffering")
                    Player.STATE_READY -> {
                        val state = if (player.isPlaying) "playing" else "ready"
                        onState(controllerId, state)
                    }

                    Player.STATE_ENDED -> onState(controllerId, "completed")
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                onState(controllerId, if (isPlaying) "playing" else "paused")
            }

            override fun onPlayerError(error: PlaybackException) {
                onState(controllerId, "error")
            }
        }
    }

    private fun emitPositions() {
        for ((controllerId, managedPlayer) in managedPlayers) {
            val player = managedPlayer.player
            if (player.playbackState != Player.STATE_IDLE) {
                val clampedPosition = player.currentPosition.coerceAtLeast(0L)
                onPosition(controllerId, clampedPosition)
            }
        }
    }

    private fun startTickerIfNeeded() {
        if (tickerRunning) {
            return
        }
        tickerRunning = true
        handler.post(positionTicker)
    }

    private fun releaseController(
        controllerId: Int,
        emitDisposed: Boolean
    ) {
        val managedPlayer = managedPlayers.remove(controllerId) ?: return
        creationOrder.remove(controllerId)
        managedPlayer.player.removeListener(managedPlayer.listener)
        managedPlayer.player.stop()
        managedPlayer.player.release()
        if (emitDisposed) {
            onState(controllerId, "disposed")
        }
    }

    private companion object {
        private const val POSITION_TICK_MS = 250L
    }
}
