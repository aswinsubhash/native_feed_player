package com.example.native_reels_player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl
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

    private data class PreloadedPlayer(
        val url: String,
        val player: ExoPlayer
    )

    private val appContext = context.applicationContext
    private val managedPlayers = mutableMapOf<Int, ManagedPlayer>()
    private val creationOrder = ArrayDeque<Int>()
    private val preloadedPlayers = mutableMapOf<Int, PreloadedPlayer>()
    private val sourcesByIndex = mutableMapOf<Int, String>()
    private val handler = Handler(Looper.getMainLooper())

    private var maxCachedPlayers = 5
    private var preloadCount = 2
    private var visibleIndex = 0
    private var preloadGeneration = 0
    private var tickerRunning = false
    private var loadControl: LoadControl = createLoadControl()

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
        this.loadControl = createLoadControl()
        schedulePreloadWindow()
    }

    fun preload(sources: List<Map<*, *>>) {
        sourcesByIndex.clear()
        for (source in sources) {
            val index = (source["index"] as? Number)?.toInt() ?: continue
            val url = source["url"] as? String ?: continue
            if (url.isBlank()) {
                continue
            }
            sourcesByIndex[index] = url
        }

        if (sourcesByIndex.isNotEmpty() && visibleIndex !in sourcesByIndex.keys) {
            visibleIndex = sourcesByIndex.keys.minOrNull() ?: 0
        }

        schedulePreloadWindow()
    }

    fun createController(
        controllerId: Int,
        url: String,
        index: Int,
        autoPlay: Boolean,
        looping: Boolean
    ) {
        evictToPoolSizeIfNeeded()

        val preloaded = preloadedPlayers.remove(index)
        val player = if (preloaded != null && preloaded.url == url) {
            preloaded.player
        } else {
            preloaded?.player?.release()
            createConfiguredPlayer().apply {
                setMediaItem(MediaItem.fromUri(Uri.parse(url)))
                prepare()
            }
        }

        val listener = playerListener(controllerId, player)
        player.addListener(listener)
        player.repeatMode = if (looping) {
            Player.REPEAT_MODE_ONE
        } else {
            Player.REPEAT_MODE_OFF
        }

        managedPlayers[controllerId] = ManagedPlayer(player = player, listener = listener)
        creationOrder.addLast(controllerId)

        if (player.playbackState == Player.STATE_IDLE) {
            onState(controllerId, "preparing")
            player.prepare()
        } else {
            emitCurrentPlaybackState(controllerId, player)
        }

        if (autoPlay) {
            player.playWhenReady = true
        }

        startTickerIfNeeded()
        schedulePreloadWindow()
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
        schedulePreloadWindow()
    }

    fun clearCache() {
        preloadGeneration += 1
        sourcesByIndex.clear()
        releaseAllPreloadedPlayers()
    }

    fun setVisibleIndex(index: Int) {
        visibleIndex = index
        schedulePreloadWindow()
    }

    fun disposeAll() {
        preloadGeneration += 1
        val ids = managedPlayers.keys.toList()
        for (id in ids) {
            releaseController(controllerId = id, emitDisposed = true)
        }
        releaseAllPreloadedPlayers()
        sourcesByIndex.clear()
        creationOrder.clear()
        handler.removeCallbacks(positionTicker)
        tickerRunning = false
    }

    private fun schedulePreloadWindow() {
        preloadGeneration += 1
        val generation = preloadGeneration
        val targetWindow = preloadWindowIndices()

        val staleIndices = preloadedPlayers.keys.filter { it !in targetWindow }.toList()
        for (index in staleIndices) {
            releasePreloadedPlayer(index)
        }

        for (index in targetWindow.sorted()) {
            val url = sourcesByIndex[index] ?: continue
            val existing = preloadedPlayers[index]
            if (existing != null && existing.url == url) {
                continue
            }
            if (existing != null) {
                releasePreloadedPlayer(index)
            }

            handler.post {
                if (generation != preloadGeneration) {
                    return@post
                }
                val freshUrl = sourcesByIndex[index] ?: return@post
                if (preloadedPlayers.containsKey(index)) {
                    return@post
                }

                val player = createConfiguredPlayer()
                player.repeatMode = Player.REPEAT_MODE_OFF
                player.playWhenReady = false
                player.setMediaItem(MediaItem.fromUri(Uri.parse(freshUrl)))
                player.prepare()
                preloadedPlayers[index] = PreloadedPlayer(url = freshUrl, player = player)
            }
        }
    }

    private fun preloadWindowIndices(): Set<Int> {
        if (preloadCount <= 0 || sourcesByIndex.isEmpty()) {
            return emptySet()
        }

        val minIndex = sourcesByIndex.keys.minOrNull() ?: return emptySet()
        val maxIndex = sourcesByIndex.keys.maxOrNull() ?: return emptySet()
        val start = maxOf(minIndex, visibleIndex - preloadCount)
        val end = minOf(maxIndex, visibleIndex + preloadCount)
        if (start > end) {
            return emptySet()
        }
        return (start..end).toSet()
    }

    private fun emitCurrentPlaybackState(controllerId: Int, player: ExoPlayer) {
        when (player.playbackState) {
            Player.STATE_IDLE -> onState(controllerId, "idle")
            Player.STATE_BUFFERING -> onState(controllerId, "buffering")
            Player.STATE_READY -> onState(controllerId, if (player.isPlaying) "playing" else "ready")
            Player.STATE_ENDED -> onState(controllerId, "completed")
        }
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

    private fun createConfiguredPlayer(): ExoPlayer {
        return ExoPlayer.Builder(appContext)
            .setLoadControl(loadControl)
            .build()
    }

    private fun createLoadControl(): LoadControl {
        return DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                /* minBufferMs = */ 2000,
                /* maxBufferMs = */ 10000,
                /* bufferForPlaybackMs = */ 1000,
                /* bufferForPlaybackAfterRebufferMs = */ 2000
            )
            .build()
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

    private fun releasePreloadedPlayer(index: Int) {
        val preloaded = preloadedPlayers.remove(index) ?: return
        preloaded.player.stop()
        preloaded.player.release()
    }

    private fun releaseAllPreloadedPlayers() {
        val indices = preloadedPlayers.keys.toList()
        for (index in indices) {
            releasePreloadedPlayer(index)
        }
    }

    private companion object {
        private const val POSITION_TICK_MS = 250L
    }
}
