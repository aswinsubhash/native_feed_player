package com.example.native_feed_player

import android.content.ComponentCallbacks2
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.TextureView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import java.util.ArrayDeque
import kotlin.math.abs

internal class ExoPlayerManager(
    context: Context,
    private val onState: (controllerId: Int, state: String) -> Unit,
    private val onReleased: (controllerId: Int, reason: String) -> Unit,
    private val onPosition: (controllerId: Int, positionMs: Long) -> Unit,
    private val onMetrics: (controllerId: Int, metrics: Map<String, Any?>) -> Unit
) {
    private data class ManagedPlayer(
        val player: ExoPlayer,
        val listener: Player.Listener,
        val analyticsListener: AnalyticsListener,
        val index: Int,
        /**
         * Value of [visibleGeneration] when this controller was created.
         *
         * Window eviction ignores controllers created since the last
         * setVisibleIndex call, because their position cannot be judged
         * against a visible index the app has not published yet.
         */
        val createdAtVisibleGeneration: Long
    )

    private data class PreloadedPlayer(
        val url: String,
        val player: ExoPlayer
    )

    private data class PlaybackMetrics(
        val createdAtMs: Long = SystemClock.elapsedRealtime(),
        var firstFrameLatencyMs: Long? = null,
        var rebufferCount: Int = 0,
        var droppedFramesEstimate: Int = 0,
        var hasReady: Boolean = false
    )

    private val appContext = context.applicationContext
    private val managedPlayers = mutableMapOf<Int, ManagedPlayer>()
    private val creationOrder = ArrayDeque<Int>()
    private val preloadedPlayers = mutableMapOf<Int, PreloadedPlayer>()
    private val recycledPlayers = ArrayDeque<ExoPlayer>()
    private val sourcesByIndex = mutableMapOf<Int, String>()
    private val attachedTextureByController = mutableMapOf<Int, TextureView>()
    private val metricsByController = mutableMapOf<Int, PlaybackMetrics>()
    private val handler = Handler(Looper.getMainLooper())

    private var maxCachedPlayers = 5
    private var maxPooledPlayers = 5
    private var preloadCount = 2
    private var activeWindowRadius = 2
    private var visibleIndex = 0
    private var visibleGeneration = 0L
    private var preloadGeneration = 0
    private var tickerRunning = false

    /**
     * Ceiling on every ExoPlayer this manager keeps alive, across the managed,
     * preloaded, and recycled buckets combined. Capping each bucket separately
     * still allows their sum to grow without bound.
     */
    private var maxTotalPlayers = 8

    private fun totalLivePlayers(): Int =
        managedPlayers.size + preloadedPlayers.size + recycledPlayers.size

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
        this.maxPooledPlayers = maxOf(1, this.maxCachedPlayers)
        this.preloadCount = maxOf(0, preloadCount)
        this.activeWindowRadius = maxOf(1, this.preloadCount)
        this.maxTotalPlayers = this.maxCachedPlayers + this.preloadCount + 1
        releaseAllPreloadedPlayers()
        releaseAllPooledPlayers()
        enforceVisibleWindowEviction()
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

        enforceVisibleWindowEviction()
        schedulePreloadWindow()
    }

    fun createController(
        controllerId: Int,
        url: String,
        index: Int,
        autoPlay: Boolean,
        looping: Boolean
    ) {
        evictToPoolSizeIfNeeded(protectedIndex = index)

        val player = obtainPlayerFor(url = url, index = index)
        val metrics = PlaybackMetrics()
        metricsByController[controllerId] = metrics
        val listener = playerListener(controllerId, player)
        val analyticsListener = analyticsListener(controllerId)
        player.addListener(listener)
        player.addAnalyticsListener(analyticsListener)
        player.repeatMode = if (looping) {
            Player.REPEAT_MODE_ONE
        } else {
            Player.REPEAT_MODE_OFF
        }

        managedPlayers[controllerId] = ManagedPlayer(
            player = player,
            listener = listener,
            analyticsListener = analyticsListener,
            index = index,
            createdAtVisibleGeneration = visibleGeneration
        )
        creationOrder.addLast(controllerId)
        attachedTextureByController[controllerId]?.let { texture ->
            player.setVideoTextureView(texture)
        }

        if (player.playbackState == Player.STATE_IDLE) {
            onState(controllerId, "preparing")
            player.prepare()
        } else {
            emitCurrentPlaybackState(controllerId, player)
        }

        if (autoPlay) {
            player.playWhenReady = true
        }

        emitMetrics(controllerId)
        startTickerIfNeeded()
        // Runs after registration and skips this generation's new controllers,
        // so a controller requested ahead of setVisibleIndex is never torn
        // down by the window it has not been measured against yet.
        enforceVisibleWindowEviction()
        enforceTotalPlayerBudget(protectedControllerId = controllerId)
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
        releaseController(controllerId = controllerId, reason = RELEASE_DISPOSED)
        schedulePreloadWindow()
    }

    fun clearCache() {
        preloadGeneration += 1
        sourcesByIndex.clear()
        releaseAllPreloadedPlayers()
    }

    fun setVisibleIndex(index: Int) {
        visibleIndex = index
        visibleGeneration += 1
        enforceVisibleWindowEviction()
        enforceTotalPlayerBudget()
        schedulePreloadWindow()
    }

    fun attachControllerToView(
        controllerId: Int,
        textureView: TextureView
    ) {
        attachedTextureByController[controllerId] = textureView
        managedPlayers[controllerId]?.player?.setVideoTextureView(textureView)
    }

    fun detachControllerFromView(controllerId: Int) {
        val textureView = attachedTextureByController.remove(controllerId) ?: return
        managedPlayers[controllerId]?.player?.clearVideoTextureView(textureView)
    }

    /**
     * Maps a trim level to a pressure response.
     *
     * The levels are not ordered by severity: TRIM_MEMORY_UI_HIDDEN (20) sits
     * numerically above TRIM_MEMORY_RUNNING_CRITICAL (15) but only means the
     * app was backgrounded. Comparing with `>=` therefore treats an ordinary
     * background transition as a critical event and destroys the whole pool.
     * Each level is matched explicitly instead.
     */
    fun onTrimMemory(level: Int) {
        when (level) {
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL,
            ComponentCallbacks2.TRIM_MEMORY_COMPLETE -> handleCriticalMemoryPressure()

            ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW,
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE,
            ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN,
            ComponentCallbacks2.TRIM_MEMORY_BACKGROUND,
            ComponentCallbacks2.TRIM_MEMORY_MODERATE -> handleModerateMemoryPressure()
        }
    }

    fun onLowMemory() {
        handleCriticalMemoryPressure()
    }

    fun disposeAll() {
        preloadGeneration += 1
        val ids = managedPlayers.keys.toList()
        for (id in ids) {
            releaseController(controllerId = id, reason = RELEASE_ENGINE_DETACHED)
        }
        attachedTextureByController.clear()
        metricsByController.clear()
        releaseAllPreloadedPlayers()
        releaseAllPooledPlayers()
        sourcesByIndex.clear()
        creationOrder.clear()
        handler.removeCallbacks(positionTicker)
        tickerRunning = false
    }

    private fun handleModerateMemoryPressure() {
        preloadGeneration += 1
        releaseAllPreloadedPlayers()
        shrinkPooledPlayers(targetSize = maxPooledPlayers / 2)
        enforceVisibleWindowEviction()
    }

    private fun handleCriticalMemoryPressure() {
        preloadGeneration += 1
        releaseAllPreloadedPlayers()
        shrinkPooledPlayers(targetSize = 0)
        enforceVisibleWindowEviction(forceAggressive = true)
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
                // Preloading is best-effort: never let it push the process
                // past the global player budget.
                if (totalLivePlayers() >= maxTotalPlayers) {
                    return@post
                }

                val player = obtainReusablePlayer()
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

    private fun enforceVisibleWindowEviction(forceAggressive: Boolean = false) {
        if (managedPlayers.isEmpty()) {
            return
        }

        val radius = if (forceAggressive) 0 else activeWindowRadius
        val minIndex = visibleIndex - radius
        val maxIndex = visibleIndex + radius
        val toEvict = managedPlayers
            .filterValues { managed ->
                val outsideWindow = managed.index >= 0 &&
                    (managed.index < minIndex || managed.index > maxIndex)
                // Controllers created since the last setVisibleIndex have not
                // been measured against a current window yet.
                val measurable = forceAggressive ||
                    managed.createdAtVisibleGeneration != visibleGeneration
                outsideWindow && measurable
            }
            .keys
            .toList()

        for (controllerId in toEvict) {
            releaseController(controllerId = controllerId, reason = RELEASE_EVICTED)
        }
    }

    /**
     * Trims the combined player count back under [maxTotalPlayers], cheapest
     * bucket first: recycled players hold no state, preloaded players can be
     * rebuilt, managed players are last resort.
     */
    private fun enforceTotalPlayerBudget(protectedControllerId: Int? = null) {
        while (totalLivePlayers() > maxTotalPlayers && recycledPlayers.isNotEmpty()) {
            recycledPlayers.removeFirst().release()
        }

        while (totalLivePlayers() > maxTotalPlayers && preloadedPlayers.isNotEmpty()) {
            val farthest = preloadedPlayers.keys.maxByOrNull { abs(it - visibleIndex) } ?: break
            val preloaded = preloadedPlayers.remove(farthest) ?: break
            preloaded.player.release()
        }

        while (totalLivePlayers() > maxTotalPlayers) {
            val candidate = managedPlayers.keys
                .filter { it != protectedControllerId }
                .maxByOrNull { id ->
                    val idx = managedPlayers[id]?.index ?: return@maxByOrNull Int.MAX_VALUE / 4
                    if (idx < 0) Int.MAX_VALUE / 4 else abs(idx - visibleIndex)
                } ?: break
            releaseController(controllerId = candidate, reason = RELEASE_EVICTED)
        }
    }

    private fun obtainPlayerFor(
        url: String,
        index: Int
    ): ExoPlayer {
        val preloaded = preloadedPlayers.remove(index)
        if (preloaded != null && preloaded.url == url) {
            return preloaded.player
        }

        preloaded?.let { recycleOrReleasePlayer(it.player) }
        return obtainReusablePlayer().apply {
            setMediaItem(MediaItem.fromUri(Uri.parse(url)))
            prepare()
        }
    }

    private fun obtainReusablePlayer(): ExoPlayer {
        val pooled = if (recycledPlayers.isEmpty()) {
            null
        } else {
            recycledPlayers.removeFirst()
        }
        if (pooled != null) {
            return pooled
        }
        return createConfiguredPlayer()
    }

    private fun emitCurrentPlaybackState(controllerId: Int, player: ExoPlayer) {
        when (player.playbackState) {
            Player.STATE_IDLE -> onState(controllerId, "idle")
            Player.STATE_BUFFERING -> onState(controllerId, "buffering")
            Player.STATE_READY -> onState(controllerId, if (player.isPlaying) "playing" else "ready")
            Player.STATE_ENDED -> onState(controllerId, "completed")
        }
    }

    private fun evictToPoolSizeIfNeeded(protectedIndex: Int? = null) {
        while (managedPlayers.size >= maxCachedPlayers) {
            val candidateId = evictionCandidateControllerId(protectedIndex) ?: break
            releaseController(controllerId = candidateId, reason = RELEASE_EVICTED)
        }
    }

    /**
     * Picks the controller furthest from the viewport.
     *
     * [protectedIndex] is the index a controller is about to be created for.
     * Ranking distance against it as well as the visible index stops a
     * just-requested position from being chosen as its own eviction victim
     * when the app requests neighbours before publishing a new visible index.
     */
    private fun evictionCandidateControllerId(protectedIndex: Int? = null): Int? {
        if (managedPlayers.isEmpty()) {
            return null
        }

        val candidate = managedPlayers
            .filterValues { it.index != protectedIndex }
            .maxByOrNull { entry ->
                val idx = entry.value.index
                if (idx < 0) {
                    Int.MAX_VALUE / 4
                } else {
                    minOf(
                        abs(idx - visibleIndex),
                        protectedIndex?.let { abs(idx - it) } ?: Int.MAX_VALUE
                    )
                }
            }?.key

        return candidate ?: creationOrder.firstOrNull { managedPlayers[it]?.index != protectedIndex }
    }

    private fun playerListener(controllerId: Int, player: ExoPlayer): Player.Listener {
        return object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                val metrics = metricsByController[controllerId]
                when (playbackState) {
                    Player.STATE_IDLE -> onState(controllerId, "idle")
                    Player.STATE_BUFFERING -> {
                        if (metrics?.hasReady == true) {
                            metrics.rebufferCount += 1
                            emitMetrics(controllerId)
                        }
                        onState(controllerId, "buffering")
                    }
                    Player.STATE_READY -> {
                        metrics?.hasReady = true
                        emitMetrics(controllerId)
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

            override fun onRenderedFirstFrame() {
                val metrics = metricsByController[controllerId] ?: return
                if (metrics.firstFrameLatencyMs == null) {
                    val now = SystemClock.elapsedRealtime()
                    metrics.firstFrameLatencyMs = (now - metrics.createdAtMs).coerceAtLeast(0L)
                    emitMetrics(controllerId)
                }
            }
        }
    }

    private fun analyticsListener(controllerId: Int): AnalyticsListener {
        return object : AnalyticsListener {
            override fun onDroppedVideoFrames(
                eventTime: AnalyticsListener.EventTime,
                droppedFrames: Int,
                elapsedMs: Long
            ) {
                if (droppedFrames <= 0) {
                    return
                }
                val metrics = metricsByController[controllerId] ?: return
                metrics.droppedFramesEstimate += droppedFrames
                emitMetrics(controllerId)
            }
        }
    }

    private fun emitMetrics(controllerId: Int) {
        val metrics = metricsByController[controllerId] ?: return
        onMetrics(
            controllerId,
            mapOf(
                "controllerId" to controllerId,
                "rebufferCount" to metrics.rebufferCount,
                "droppedFramesEstimate" to metrics.droppedFramesEstimate,
                "firstFrameLatencyMs" to metrics.firstFrameLatencyMs,
                "timestampMs" to System.currentTimeMillis()
            )
        )
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
            .setLoadControl(createLoadControl())
            .build()
    }

    private fun createLoadControl(): DefaultLoadControl {
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
        reason: String
    ) {
        val managedPlayer = managedPlayers.remove(controllerId) ?: return
        creationOrder.remove(controllerId)
        managedPlayer.player.removeListener(managedPlayer.listener)
        managedPlayer.player.removeAnalyticsListener(managedPlayer.analyticsListener)
        attachedTextureByController.remove(controllerId)?.let { texture ->
            managedPlayer.player.clearVideoTextureView(texture)
        }
        metricsByController.remove(controllerId)
        recycleOrReleasePlayer(managedPlayer.player)
        onReleased(controllerId, reason)
    }

    private fun releasePreloadedPlayer(index: Int) {
        val preloaded = preloadedPlayers.remove(index) ?: return
        recycleOrReleasePlayer(preloaded.player)
    }

    private fun releaseAllPreloadedPlayers() {
        val indices = preloadedPlayers.keys.toList()
        for (index in indices) {
            releasePreloadedPlayer(index)
        }
    }

    private fun recycleOrReleasePlayer(player: ExoPlayer) {
        player.stop()
        player.clearMediaItems()
        player.playWhenReady = false
        player.repeatMode = Player.REPEAT_MODE_OFF
        if (recycledPlayers.size < maxPooledPlayers) {
            recycledPlayers.addLast(player)
        } else {
            player.release()
        }
    }

    private fun shrinkPooledPlayers(targetSize: Int) {
        while (recycledPlayers.size > targetSize) {
            val player = recycledPlayers.removeFirst()
            player.release()
        }
    }

    private fun releaseAllPooledPlayers() {
        shrinkPooledPlayers(targetSize = 0)
    }

    internal companion object {
        private const val POSITION_TICK_MS = 250L

        const val RELEASE_DISPOSED = "disposed"
        const val RELEASE_EVICTED = "evicted"
        const val RELEASE_ENGINE_DETACHED = "engine_detached"
    }
}
