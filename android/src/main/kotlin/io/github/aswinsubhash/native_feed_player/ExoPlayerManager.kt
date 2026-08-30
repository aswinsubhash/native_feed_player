package io.github.aswinsubhash.native_feed_player

import android.content.ComponentCallbacks2
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import android.view.TextureView
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import java.util.ArrayDeque

/** Time-based adaptive policy that ignores isolated stalls and recovers only after stability. */
internal class AdaptivePreloadPolicy {
    private val recentRebuffersMs = ArrayDeque<Long>()
    private var lastInstabilityMs: Long? = null

    var scale: Double = 1.0
        private set

    fun recordRebuffer(nowMs: Long): Boolean {
        lastInstabilityMs = nowMs
        while (recentRebuffersMs.isNotEmpty() &&
            nowMs - recentRebuffersMs.first() > REBUFFER_WINDOW_MS
        ) {
            recentRebuffersMs.removeFirst()
        }
        recentRebuffersMs.addLast(nowMs)
        if (recentRebuffersMs.size < REBUFFERS_BEFORE_DEGRADE) {
            return false
        }
        recentRebuffersMs.clear()
        val next = (scale / 2).coerceAtLeast(MIN_SCALE)
        if (next == scale) {
            return false
        }
        scale = next
        return true
    }

    fun recordSteadyPlayback(nowMs: Long): Boolean {
        val lastInstability = lastInstabilityMs ?: return false
        if (scale >= 1.0 || nowMs - lastInstability < RECOVERY_INTERVAL_MS) {
            return false
        }
        scale = (scale * 2).coerceAtMost(1.0)
        lastInstabilityMs = nowMs
        recentRebuffersMs.clear()
        return true
    }

    fun forceMinimum(nowMs: Long): Boolean {
        val changed = scale != MIN_SCALE
        scale = MIN_SCALE
        lastInstabilityMs = nowMs
        recentRebuffersMs.clear()
        return changed
    }

    fun reset() {
        scale = 1.0
        lastInstabilityMs = null
        recentRebuffersMs.clear()
    }

    internal companion object {
        const val REBUFFERS_BEFORE_DEGRADE = 3
        const val REBUFFER_WINDOW_MS = 30_000L
        const val RECOVERY_INTERVAL_MS = 30_000L
        const val MIN_SCALE = 0.25
    }
}

internal fun mapPlaybackStatus(
    playbackState: Int,
    isPlaying: Boolean,
    hasPlayerError: Boolean,
    hasEverPlayed: Boolean
): PlaybackStatusMessage = when {
    hasPlayerError -> PlaybackStatusMessage.ERROR
    playbackState == Player.STATE_IDLE -> PlaybackStatusMessage.IDLE
    playbackState == Player.STATE_BUFFERING -> PlaybackStatusMessage.BUFFERING
    playbackState == Player.STATE_ENDED -> PlaybackStatusMessage.COMPLETED
    playbackState == Player.STATE_READY && isPlaying -> PlaybackStatusMessage.PLAYING
    playbackState == Player.STATE_READY && hasEverPlayed -> PlaybackStatusMessage.PAUSED
    playbackState == Player.STATE_READY -> PlaybackStatusMessage.READY
    else -> PlaybackStatusMessage.IDLE
}

/** Owns ExoPlayer instances, preload scheduling, and eviction. */
@OptIn(UnstableApi::class)
internal class ExoPlayerManager(
    context: Context,
    private val onState: (controllerId: Int, status: PlaybackStatusMessage, error: PlaybackErrorMessage?) -> Unit,
    private val onReleased: (controllerId: Int, reason: ReleaseReasonMessage) -> Unit,
    private val onPosition: (event: PositionEvent) -> Unit,
    private val onMetrics: (event: MetricsEvent) -> Unit,
    private val onVideoSize: (event: VideoSizeEvent) -> Unit
) {
    private class ManagedPlayer(
        val player: ExoPlayer,
        val listener: Player.Listener,
        val analyticsListener: AnalyticsListener,
        val sourceId: String,
        val sourceIdentity: String,
        val sourceKind: FeedMediaKindMessage,
        var targetVolume: Float,
        var isMuted: Boolean,
        /** Creation-time visibility generation used to defer eviction. */
        val createdAtVisibleGeneration: Long
    )

    private class PlaybackMetrics {
        val createdAtMs: Long = SystemClock.elapsedRealtime()
        var firstFrameLatencyMs: Long? = null
        var rebufferCount: Int = 0
        var droppedFrames: Int = 0
        var hasBeenReady: Boolean = false
        var hasEverPlayed: Boolean = false
    }

    private val appContext = context.applicationContext
    private val registry = FeedSourceRegistry()
    private val managedPlayers = mutableMapOf<Int, ManagedPlayer>()
    private val creationOrder = ArrayDeque<Int>()
    private val recycledPlayers = ArrayDeque<ExoPlayer>()
    private var preloadManager: FeedPreloadManager? = null
    private val attachedTextureByController = mutableMapOf<Int, TextureView>()
    private val surfaceByController = mutableMapOf<Int, Surface>()
    private val metricsByController = mutableMapOf<Int, PlaybackMetrics>()
    private val handler = Handler(Looper.getMainLooper())

    private var maxActivePlayers = 3
    private var preloadAhead = 2
    private var preloadBehind = 1
    private var maxConcurrentPreloads = 2
    private var positionIntervalMs = 200L
    private var muted = false
    private var volume = 1.0f
    private var handleAudioFocus = true

    /** Controllers paused by backgrounding, to be resumed on return. */
    private val autoPausedControllerIds = mutableSetOf<Int>()
    private var visibleGeneration = 0L
    private var preloadGeneration = 0
    private var tickerRunning = false

    /** Preload-window multiplier reduced under clustered stalls or memory pressure. */
    private val adaptivePreloadPolicy = AdaptivePreloadPolicy()

    /** Maximum combined active and recycled player count. */
    private var maxTotalPlayers = 6

    private fun totalLivePlayers(): Int = managedPlayers.size + recycledPlayers.size

    private val positionTicker = object : Runnable {
        override fun run() {
            emitPositions()
            if (managedPlayers.isNotEmpty()) {
                handler.postDelayed(this, positionIntervalMs)
            } else {
                tickerRunning = false
            }
        }
    }

    fun initialize(config: FeedPlayerConfigMessage) {
        resetSession(ReleaseReasonMessage.DISPOSED)
        maxActivePlayers = maxOf(1, config.maxActivePlayers.toInt())
        preloadAhead = maxOf(0, config.preloadAhead.toInt())
        preloadBehind = maxOf(0, config.preloadBehind.toInt())
        maxConcurrentPreloads = maxOf(1, config.maxConcurrentPreloads.toInt())
        positionIntervalMs = maxOf(50L, config.positionUpdateIntervalMs)
        applyAudioPolicy(config.audio)
        // Preloading does not retain players.
        maxTotalPlayers = maxActivePlayers * 2

        MediaCache.configure(
            context = appContext,
            enabled = config.cache.enabled,
            maxBytes = config.cache.maxBytes
        )

        // Rebuild shared Media3 components for the new configuration.
        releaseAllPooledPlayers()
        preloadManager?.release()
        preloadManager = FeedPreloadManager(appContext)
            .apply { setMaxPreloadDistance(maxOf(preloadAhead, preloadBehind)) }

        enforceVisibleWindowEviction()
        schedulePreloadWindow()
    }

    fun setSources(sources: List<RegisteredSource>) {
        registry.replaceAll(sources)
        val orphanedControllerIds = managedPlayers.filterValues { managed ->
            registry.isOrphaned(managed.sourceId, managed.sourceIdentity, managed.sourceKind)
        }.keys.toList()
        for (controllerId in orphanedControllerIds) {
            releaseController(controllerId, ReleaseReasonMessage.DISPOSED)
        }
        preloadManager?.reset()
        enforceVisibleWindowEviction()
        schedulePreloadWindow()
    }

    fun appendSources(sources: List<RegisteredSource>) {
        registry.append(sources)
        schedulePreloadWindow()
    }

    fun removeSources(sourceIds: List<String>) {
        registry.remove(sourceIds)
        for (sourceId in sourceIds) {
            val controllerIds = managedPlayers
                .filterValues { it.sourceId == sourceId }
                .keys
                .toList()
            for (controllerId in controllerIds) {
                releaseController(controllerId, ReleaseReasonMessage.DISPOSED)
            }
        }
        schedulePreloadWindow()
    }

    fun createController(
        controllerId: Int,
        sourceId: String,
        autoPlay: Boolean,
        looping: Boolean
    ) {
        val source = registry.source(sourceId)
            ?: throw FlutterError(
                "source_not_found",
                "No registered source with id=$sourceId. Call setSources first.",
                null
            )

        evictToActiveLimit(protectedSourceId = sourceId)

        val player = obtainPlayerFor(source)
        metricsByController[controllerId] = PlaybackMetrics()
        val listener = playerListener(controllerId)
        val analyticsListener = analyticsListener(controllerId)
        player.addListener(listener)
        player.addAnalyticsListener(analyticsListener)
        player.repeatMode = if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
        player.volume = if (muted) 0f else volume
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .setUsage(C.USAGE_MEDIA)
                .build(),
            handleAudioFocus
        )
        // Keep the CPU awake only for audible playback.
        player.setWakeMode(if (muted) C.WAKE_MODE_NONE else C.WAKE_MODE_NETWORK)

        managedPlayers[controllerId] = ManagedPlayer(
            player = player,
            listener = listener,
            analyticsListener = analyticsListener,
            sourceId = sourceId,
            sourceIdentity = source.cacheIdentity,
            sourceKind = source.kind,
            targetVolume = volume,
            isMuted = muted,
            createdAtVisibleGeneration = visibleGeneration
        )
        creationOrder.addLast(controllerId)
        attachedTextureByController[controllerId]?.let { player.setVideoTextureView(it) }
        surfaceByController[controllerId]?.let { player.setVideoSurface(it) }

        if (player.playbackState == Player.STATE_IDLE) {
            onState(controllerId, PlaybackStatusMessage.PREPARING, null)
            player.prepare()
        } else {
            emitCurrentPlaybackState(controllerId, player)
        }

        if (autoPlay) {
            player.playWhenReady = true
        }

        emitMetrics(controllerId)
        startTickerIfNeeded()
        // Apply eviction after controller registration.
        enforceVisibleWindowEviction()
        enforceTotalPlayerBudget(protectedControllerId = controllerId)
        schedulePreloadWindow()
    }

    fun play(controllerId: Int) {
        autoPausedControllerIds.remove(controllerId)
        managedPlayers[controllerId]?.player?.play()
    }

    fun setVolume(controllerId: Int, value: Double) {
        val managed = managedPlayers[controllerId] ?: return
        managed.targetVolume = value.toFloat().coerceIn(0f, 1f)
        managed.player.volume = if (managed.isMuted) 0f else managed.targetVolume
    }

    fun setMuted(controllerId: Int, value: Boolean) {
        val managed = managedPlayers[controllerId] ?: return
        managed.isMuted = value
        managed.player.volume = if (value) 0f else managed.targetVolume
        managed.player.setWakeMode(if (value) C.WAKE_MODE_NONE else C.WAKE_MODE_NETWORK)
    }

    fun setPlaybackSpeed(controllerId: Int, speed: Double) {
        val clamped = speed.toFloat().coerceIn(0.25f, 4f)
        managedPlayers[controllerId]?.player?.setPlaybackSpeed(clamped)
    }

    fun setLooping(controllerId: Int, looping: Boolean) {
        managedPlayers[controllerId]?.player?.repeatMode =
            if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
    }

    /** Applies audio policy to current and future players. */
    fun applyAudioPolicy(policy: AudioPolicyMessage) {
        muted = policy.muted
        volume = policy.volume.toFloat().coerceIn(0f, 1f)
        handleAudioFocus = policy.handleAudioFocus && !policy.muted

        val attributes = AudioAttributes.Builder()
            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
            .setUsage(C.USAGE_MEDIA)
            .build()

        for (managed in managedPlayers.values) {
            managed.targetVolume = volume
            managed.isMuted = muted
            managed.player.setAudioAttributes(attributes, handleAudioFocus)
            managed.player.volume = if (muted) 0f else volume
            managed.player.setWakeMode(if (muted) C.WAKE_MODE_NONE else C.WAKE_MODE_NETWORK)
        }
    }

    /** Pauses active players until the app returns to the foreground. */
    fun onAppBackgrounded() {
        for ((controllerId, managed) in managedPlayers) {
            if (managed.player.isPlaying) {
                autoPausedControllerIds.add(controllerId)
                managed.player.pause()
            }
        }
    }

    fun onAppForegrounded() {
        for (controllerId in autoPausedControllerIds.toList()) {
            managedPlayers[controllerId]?.player?.play()
        }
        autoPausedControllerIds.clear()
    }

    fun pause(controllerId: Int) {
        autoPausedControllerIds.remove(controllerId)
        managedPlayers[controllerId]?.player?.pause()
    }

    fun seekTo(controllerId: Int, positionMs: Long) {
        managedPlayers[controllerId]?.player?.seekTo(positionMs.coerceAtLeast(0L))
    }

    fun disposeController(controllerId: Int) {
        releaseController(controllerId, ReleaseReasonMessage.DISPOSED)
        schedulePreloadWindow()
    }

    fun setVisibleSource(sourceId: String) {
        if (!registry.setVisible(sourceId)) {
            return
        }
        visibleGeneration += 1
        enforceVisibleWindowEviction()
        enforceTotalPlayerBudget()
        schedulePreloadWindow()
    }

    fun attachControllerToView(controllerId: Int, textureView: TextureView) {
        attachedTextureByController[controllerId] = textureView
        managedPlayers[controllerId]?.player?.setVideoTextureView(textureView)
    }

    fun detachControllerFromView(controllerId: Int) {
        val textureView = attachedTextureByController.remove(controllerId) ?: return
        managedPlayers[controllerId]?.player?.clearVideoTextureView(textureView)
    }

    fun bindSurface(controllerId: Int, surface: Surface) {
        surfaceByController[controllerId] = surface
        managedPlayers[controllerId]?.player?.setVideoSurface(surface)
    }

    fun unbindSurface(controllerId: Int) {
        surfaceByController.remove(controllerId)
        managedPlayers[controllerId]?.player?.setVideoSurface(null)
    }

    /** True when the controller has any video output bound. */
    private fun hasVideoOutput(controllerId: Int): Boolean =
        attachedTextureByController.containsKey(controllerId) ||
            surfaceByController.containsKey(controllerId)

    /** Maps non-severity-ordered trim levels to explicit pressure responses. */
    @Suppress("DEPRECATION")
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
        resetSession(ReleaseReasonMessage.ENGINE_DETACHED)
    }

    private fun resetSession(reason: ReleaseReasonMessage) {
        preloadGeneration += 1
        // Release shared preload components before their players.
        preloadManager?.release()
        preloadManager = null
        for (id in managedPlayers.keys.toList()) {
            releaseController(id, reason)
        }
        attachedTextureByController.clear()
        surfaceByController.clear()
        metricsByController.clear()
        releaseAllPooledPlayers()
        registry.clear()
        creationOrder.clear()
        autoPausedControllerIds.clear()
        visibleGeneration = 0
        adaptivePreloadPolicy.reset()
        handler.removeCallbacks(positionTicker)
        tickerRunning = false
    }

    fun cacheIdentities(sourceIds: List<String>): List<String> = sourceIds.mapNotNull { sourceId ->
        registry.source(sourceId)?.cacheIdentity
    }.distinct()

    fun cacheIdentity(sourceId: String): String? = registry.source(sourceId)?.cacheIdentity

    fun cacheStatus(sourceId: String, sourceIdentity: String?): CacheStatusMessage {
        if (sourceIdentity == null) {
            return CacheStatusMessage(
                sourceId = sourceId,
                cachedBytes = 0,
                totalBytes = 0,
                isComplete = false
            )
        }
        val cached = MediaCache.cachedBytes(sourceIdentity)
        val total = MediaCache.contentLength(sourceIdentity)
        return CacheStatusMessage(
            sourceId = sourceId,
            cachedBytes = cached,
            totalBytes = total,
            isComplete = total > 0 && cached >= total
        )
    }

    /** Reduces the preload window only after stalls cluster in a bounded interval. */
    private fun noteRebuffer() {
        if (adaptivePreloadPolicy.recordRebuffer(SystemClock.elapsedRealtime())) {
            schedulePreloadWindow()
        }
    }

    /** Restores one step only after a full stable-playback interval. */
    private fun noteSteadyPlayback() {
        if (adaptivePreloadPolicy.recordSteadyPlayback(SystemClock.elapsedRealtime())) {
            schedulePreloadWindow()
        }
    }

    private fun handleModerateMemoryPressure() {
        preloadGeneration += 1
        preloadManager?.reset()
        shrinkPooledPlayers(targetSize = 0)
        enforceVisibleWindowEviction()
        schedulePreloadWindow()
    }

    private fun handleCriticalMemoryPressure() {
        preloadGeneration += 1
        adaptivePreloadPolicy.forceMinimum(SystemClock.elapsedRealtime())
        preloadManager?.reset()
        shrinkPooledPlayers(targetSize = 0)
        enforceVisibleWindowEviction(forceAggressive = true)
    }

    /** Coalesces preload-window updates on the main looper. */
    private fun schedulePreloadWindow() {
        preloadGeneration += 1
        val generation = preloadGeneration

        handler.post {
            if (generation != preloadGeneration) {
                return@post
            }
            val manager = preloadManager ?: return@post
            val visibleRank = registry.visibleRank() ?: return@post
            val window = registry.preloadWindow(
                ahead = preloadAhead,
                behind = preloadBehind,
                scale = adaptivePreloadPolicy.scale
            ).take(maxConcurrentPreloads + 1)

            manager.setMaxPreloadDistance(maxOf(preloadAhead, preloadBehind))
            manager.sync(window = window, visibleRank = visibleRank)
        }
    }

    private fun enforceVisibleWindowEviction(forceAggressive: Boolean = false) {
        if (managedPlayers.isEmpty()) {
            return
        }

        val keepAhead = if (forceAggressive) 0 else preloadAhead
        val keepBehind = if (forceAggressive) 0 else preloadBehind
        val visibleRank = registry.visibleRank() ?: return

        val toEvict = managedPlayers.filterValues { managed ->
            val rank = registry.source(managed.sourceId)?.rank
            val outsideWindow = rank == null || (rank - visibleRank) !in -keepBehind..keepAhead
            // Defer eviction until the next visibility generation.
            val measurable = forceAggressive ||
                managed.createdAtVisibleGeneration != visibleGeneration
            outsideWindow && measurable
        }.keys.toList()

        for (controllerId in toEvict) {
            releaseController(controllerId, ReleaseReasonMessage.EVICTED)
        }
    }

    /** Enforces the player budget by releasing recycled players first. */
    private fun enforceTotalPlayerBudget(protectedControllerId: Int? = null) {
        while (totalLivePlayers() > maxTotalPlayers && recycledPlayers.isNotEmpty()) {
            recycledPlayers.removeFirst().release()
        }

        while (totalLivePlayers() > maxTotalPlayers) {
            val candidate = managedPlayers.keys
                .filter { it != protectedControllerId }
                .maxByOrNull { distanceOrFar(managedPlayers[it]?.sourceId) } ?: break
            releaseController(candidate, ReleaseReasonMessage.EVICTED)
        }
    }

    private fun evictToActiveLimit(protectedSourceId: String?) {
        while (managedPlayers.size >= maxActivePlayers) {
            val candidate = evictionCandidate(protectedSourceId) ?: break
            releaseController(candidate, ReleaseReasonMessage.EVICTED)
        }
    }

    /** Selects the furthest controller outside [protectedSourceId]. */
    private fun evictionCandidate(protectedSourceId: String?): Int? {
        val eligible = managedPlayers.filterValues { it.sourceId != protectedSourceId }
        if (eligible.isEmpty()) {
            return null
        }
        return eligible.keys.maxByOrNull { distanceOrFar(eligible[it]?.sourceId) }
            ?: creationOrder.firstOrNull { managedPlayers[it]?.sourceId != protectedSourceId }
    }

    private fun distanceOrFar(sourceId: String?): Int {
        if (sourceId == null) {
            return Int.MAX_VALUE / 4
        }
        return registry.distanceFromVisible(sourceId) ?: (Int.MAX_VALUE / 4)
    }

    /** Uses preloaded media with a player from the same preload manager. */
    private fun obtainPlayerFor(source: RegisteredSource): ExoPlayer {
        val player = obtainReusablePlayer()
        val preloadedSource = preloadManager?.mediaSourceFor(source)
        if (preloadedSource != null) {
            player.setMediaSource(preloadedSource)
        } else {
            player.setMediaSource(MediaCache.createMediaSource(source))
        }
        return player
    }

    private fun obtainReusablePlayer(): ExoPlayer {
        if (recycledPlayers.isNotEmpty()) {
            return recycledPlayers.removeFirst()
        }
        return preloadManager?.buildPlayer() ?: createFallbackPlayer()
    }

    private fun emitCurrentPlaybackState(controllerId: Int, player: ExoPlayer) {
        val error = player.playerError
        val status = mapPlaybackStatus(
            playbackState = player.playbackState,
            isPlaying = player.isPlaying,
            hasPlayerError = error != null,
            hasEverPlayed = metricsByController[controllerId]?.hasEverPlayed == true
        )
        onState(controllerId, status, error?.let(PlaybackErrorMapper::map))
    }

    private fun playerListener(controllerId: Int): Player.Listener {
        return object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                val metrics = metricsByController[controllerId]
                if (playbackState == Player.STATE_BUFFERING && metrics?.hasBeenReady == true) {
                    metrics.rebufferCount += 1
                    noteRebuffer()
                    emitMetrics(controllerId)
                } else if (playbackState == Player.STATE_READY) {
                    metrics?.hasBeenReady = true
                    emitMetrics(controllerId)
                }
            }

            override fun onEvents(player: Player, events: Player.Events) {
                if (!events.containsAny(
                        Player.EVENT_PLAYBACK_STATE_CHANGED,
                        Player.EVENT_IS_PLAYING_CHANGED,
                        Player.EVENT_PLAYER_ERROR
                    )
                ) {
                    return
                }
                if (player.isPlaying) {
                    metricsByController[controllerId]?.hasEverPlayed = true
                }
                val error = player.playerError
                val status = mapPlaybackStatus(
                    playbackState = player.playbackState,
                    isPlaying = player.isPlaying,
                    hasPlayerError = error != null,
                    hasEverPlayed = metricsByController[controllerId]?.hasEverPlayed == true
                )
                onState(controllerId, status, error?.let(PlaybackErrorMapper::map))
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width <= 0 || videoSize.height <= 0) {
                    return
                }
                // Media3 reports display-oriented dimensions.
                onVideoSize(
                    VideoSizeEvent(
                        controllerId = controllerId.toLong(),
                        width = videoSize.width.toLong(),
                        height = videoSize.height.toLong(),
                        rotationDegrees = 0
                    )
                )
            }

            override fun onRenderedFirstFrame() {
                val metrics = metricsByController[controllerId] ?: return
                if (metrics.firstFrameLatencyMs == null) {
                    metrics.firstFrameLatencyMs =
                        (SystemClock.elapsedRealtime() - metrics.createdAtMs).coerceAtLeast(0L)
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
                // Match the iOS lifetime total.
                metrics.droppedFrames += droppedFrames
                emitMetrics(controllerId)
            }
        }
    }

    private fun emitMetrics(controllerId: Int) {
        val metrics = metricsByController[controllerId] ?: return
        onMetrics(
            MetricsEvent(
                controllerId = controllerId.toLong(),
                rebufferCount = metrics.rebufferCount.toLong(),
                droppedFrames = metrics.droppedFrames.toLong(),
                timestampMs = System.currentTimeMillis(),
                firstFrameLatencyMs = metrics.firstFrameLatencyMs
            )
        )
    }

    private fun emitPositions() {
        if (managedPlayers.values.any { it.player.isPlaying }) {
            noteSteadyPlayback()
        }
        for ((controllerId, managed) in managedPlayers) {
            val player = managed.player
            if (player.playbackState == Player.STATE_IDLE) {
                continue
            }
            // Skip position updates for idle offscreen players.
            val isRendering = hasVideoOutput(controllerId)
            if (!isRendering && !player.isPlaying) {
                continue
            }
            val duration = player.duration
            onPosition(
                PositionEvent(
                    controllerId = controllerId.toLong(),
                    positionMs = player.currentPosition.coerceAtLeast(0L),
                    bufferedPositionMs = player.bufferedPosition.coerceAtLeast(0L),
                    durationMs = if (duration > 0) duration else null
                )
            )
        }
    }

    private fun startTickerIfNeeded() {
        if (tickerRunning) {
            return
        }
        tickerRunning = true
        handler.post(positionTicker)
    }

    /** Creates a player before shared preload components are initialized. */
    private fun createFallbackPlayer(): ExoPlayer = ExoPlayer.Builder(appContext).build()

    private fun releaseController(controllerId: Int, reason: ReleaseReasonMessage) {
        val managed = managedPlayers.remove(controllerId) ?: return
        creationOrder.remove(controllerId)
        managed.player.removeListener(managed.listener)
        managed.player.removeAnalyticsListener(managed.analyticsListener)
        attachedTextureByController.remove(controllerId)?.let { texture ->
            managed.player.clearVideoTextureView(texture)
        }
        if (surfaceByController.remove(controllerId) != null) {
            managed.player.setVideoSurface(null)
        }
        metricsByController.remove(controllerId)
        autoPausedControllerIds.remove(controllerId)
        recycleOrReleasePlayer(managed.player)
        onReleased(controllerId, reason)
    }

    private fun recycleOrReleasePlayer(player: ExoPlayer) {
        player.stop()
        player.clearMediaItems()
        player.playWhenReady = false
        player.repeatMode = Player.REPEAT_MODE_OFF
        if (recycledPlayers.size < maxActivePlayers) {
            recycledPlayers.addLast(player)
        } else {
            player.release()
        }
    }

    private fun shrinkPooledPlayers(targetSize: Int) {
        while (recycledPlayers.size > targetSize) {
            recycledPlayers.removeFirst().release()
        }
    }

    private fun releaseAllPooledPlayers() {
        shrinkPooledPlayers(targetSize = 0)
    }
}
