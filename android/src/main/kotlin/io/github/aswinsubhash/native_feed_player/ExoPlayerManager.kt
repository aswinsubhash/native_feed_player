package io.github.aswinsubhash.native_feed_player

import android.content.ComponentCallbacks2
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import android.view.TextureView
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import java.util.ArrayDeque

/**
 * Owns every ExoPlayer instance and the scheduling policy around them.
 *
 * Controllers are addressed by id and bound to a [RegisteredSource]; feed
 * position is only used to rank preload priority and eviction distance.
 */
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
        /**
         * Value of [visibleGeneration] when this controller was created.
         *
         * Window eviction ignores controllers created since the last visible
         * source update, because their position cannot be judged against a
         * viewport the app has not published yet.
         */
        val createdAtVisibleGeneration: Long
    )

    private class PlaybackMetrics {
        val createdAtMs: Long = SystemClock.elapsedRealtime()
        var firstFrameLatencyMs: Long? = null
        var rebufferCount: Int = 0
        var droppedFrames: Int = 0
        var hasBeenReady: Boolean = false
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
    private var muted = true
    private var volume = 1.0f
    private var handleAudioFocus = false

    /** Controllers paused by backgrounding, to be resumed on return. */
    private val autoPausedControllerIds = mutableSetOf<Int>()
    private var visibleGeneration = 0L
    private var preloadGeneration = 0
    private var tickerRunning = false

    /**
     * Shrinks the preload window when the device cannot keep up.
     *
     * Preloading competes with playback for bandwidth and memory, so under
     * sustained rebuffering or memory pressure the cheapest correction is to
     * prepare fewer items rather than to keep thrashing.
     */
    private var windowScale = 1.0
    private var rebuffersSinceLastRecovery = 0

    /**
     * Ceiling on every ExoPlayer kept alive across the managed, preloaded, and
     * recycled buckets combined. Capping each bucket separately still allows
     * their sum to grow without bound.
     */
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
        maxActivePlayers = maxOf(1, config.maxActivePlayers.toInt())
        preloadAhead = maxOf(0, config.preloadAhead.toInt())
        preloadBehind = maxOf(0, config.preloadBehind.toInt())
        maxConcurrentPreloads = maxOf(1, config.maxConcurrentPreloads.toInt())
        positionIntervalMs = maxOf(50L, config.positionUpdateIntervalMs)
        applyAudioPolicy(config.audio)
        // Preloading no longer costs a player, so the budget only has to cover
        // live controllers plus the recycle pool.
        maxTotalPlayers = maxActivePlayers * 2

        MediaCache.configure(
            context = appContext,
            enabled = config.cache.enabled,
            maxBytes = config.cache.maxBytes
        )

        // The preload manager owns the shared player components, so it must be
        // rebuilt (and every player with it) when configuration changes.
        releaseAllPooledPlayers()
        preloadManager?.release()
        preloadManager = FeedPreloadManager(appContext) { uri -> headersFor(uri) }
            .apply { setMaxPreloadDistance(maxOf(preloadAhead, preloadBehind)) }

        enforceVisibleWindowEviction()
        schedulePreloadWindow()
    }

    private fun headersFor(uri: String): Map<String, String> =
        registry.all().firstOrNull { it.uri == uri }?.headers ?: emptyMap()

    fun setSources(sources: List<RegisteredSource>) {
        registry.replaceAll(sources)
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
        val listener = playerListener(controllerId, player)
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
        // Keeps the CPU alive for audio while the screen sleeps, without
        // holding a wake lock when the feed is muted.
        player.setWakeMode(if (muted) C.WAKE_MODE_NONE else C.WAKE_MODE_NETWORK)

        managedPlayers[controllerId] = ManagedPlayer(
            player = player,
            listener = listener,
            analyticsListener = analyticsListener,
            sourceId = sourceId,
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
        // Runs after registration and skips this generation's new controllers,
        // so a controller requested ahead of setVisibleSource is never torn
        // down by a window it has not been measured against yet.
        enforceVisibleWindowEviction()
        enforceTotalPlayerBudget(protectedControllerId = controllerId)
        schedulePreloadWindow()
    }

    fun play(controllerId: Int) {
        autoPausedControllerIds.remove(controllerId)
        managedPlayers[controllerId]?.player?.play()
    }

    // MARK: - Controls

    fun setVolume(controllerId: Int, value: Double) {
        val clamped = value.toFloat().coerceIn(0f, 1f)
        managedPlayers[controllerId]?.player?.volume = if (muted) 0f else clamped
    }

    fun setMuted(controllerId: Int, value: Boolean) {
        managedPlayers[controllerId]?.player?.volume = if (value) 0f else volume
    }

    fun setPlaybackSpeed(controllerId: Int, speed: Double) {
        val clamped = speed.toFloat().coerceIn(0.25f, 4f)
        managedPlayers[controllerId]?.player?.setPlaybackSpeed(clamped)
    }

    fun setLooping(controllerId: Int, looping: Boolean) {
        managedPlayers[controllerId]?.player?.repeatMode =
            if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
    }

    /**
     * Applies audio behaviour to current and future players.
     *
     * Focus is only requested when audio is actually audible: a muted feed that
     * grabs focus would needlessly duck or pause whatever the user is listening
     * to.
     */
    fun applyAudioPolicy(policy: AudioPolicyMessage) {
        muted = policy.muted
        volume = policy.volume.toFloat().coerceIn(0f, 1f)
        handleAudioFocus = policy.handleAudioFocus && !policy.muted

        val attributes = AudioAttributes.Builder()
            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
            .setUsage(C.USAGE_MEDIA)
            .build()

        for (managed in managedPlayers.values) {
            managed.player.setAudioAttributes(attributes, handleAudioFocus)
            managed.player.volume = if (muted) 0f else volume
        }
    }

    /**
     * Pauses anything playing when the app leaves the foreground and remembers
     * it, so returning restores exactly what was interrupted.
     */
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
        registry.setVisible(sourceId)
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

    /**
     * Maps a trim level to a pressure response.
     *
     * The levels are not ordered by severity: TRIM_MEMORY_UI_HIDDEN (20) sits
     * numerically above TRIM_MEMORY_RUNNING_CRITICAL (15) but only means the
     * app was backgrounded. Comparing with `>=` therefore treats an ordinary
     * background transition as a critical event and destroys the whole pool.
     * Each level is matched explicitly instead.
     */
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
        preloadGeneration += 1
        // The preload manager shares components with every player it built, so
        // it has to go first.
        preloadManager?.release()
        preloadManager = null
        for (id in managedPlayers.keys.toList()) {
            releaseController(id, ReleaseReasonMessage.ENGINE_DETACHED)
        }
        attachedTextureByController.clear()
        surfaceByController.clear()
        metricsByController.clear()
        releaseAllPooledPlayers()
        registry.clear()
        creationOrder.clear()
        handler.removeCallbacks(positionTicker)
        tickerRunning = false
    }

    // MARK: - Cache

    fun clearMediaCache() {
        MediaCache.evictAll()
    }

    /** Evicts the given sources, or everything when [sourceIds] is empty. */
    fun evictCachedMedia(sourceIds: List<String>) {
        if (sourceIds.isEmpty()) {
            MediaCache.evictAll()
            return
        }
        for (sourceId in sourceIds) {
            val uri = registry.source(sourceId)?.uri ?: continue
            MediaCache.evict(uri)
        }
    }

    fun cacheStatus(sourceId: String): CacheStatusMessage {
        val uri = registry.source(sourceId)?.uri
            ?: return CacheStatusMessage(
                sourceId = sourceId,
                cachedBytes = 0,
                totalBytes = 0,
                isComplete = false
            )
        val cached = MediaCache.cachedBytes(uri)
        val total = MediaCache.contentLength(uri)
        return CacheStatusMessage(
            sourceId = sourceId,
            cachedBytes = cached,
            totalBytes = total,
            isComplete = total > 0 && cached >= total
        )
    }

    fun cacheUsageBytes(): Long = MediaCache.usageBytes()

    /**
     * Halves the preload window after repeated stalls, down to a floor that
     * still keeps the immediate neighbour prepared.
     */
    private fun noteRebuffer() {
        rebuffersSinceLastRecovery += 1
        if (rebuffersSinceLastRecovery < REBUFFERS_BEFORE_DEGRADE) {
            return
        }
        rebuffersSinceLastRecovery = 0
        val next = (windowScale / 2).coerceAtLeast(MIN_WINDOW_SCALE)
        if (next != windowScale) {
            windowScale = next
            schedulePreloadWindow()
        }
    }

    /** Restores the window one step at a time once playback settles. */
    private fun noteSteadyPlayback() {
        rebuffersSinceLastRecovery = 0
        if (windowScale >= 1.0) {
            return
        }
        windowScale = (windowScale * 2).coerceAtMost(1.0)
        schedulePreloadWindow()
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
        windowScale = MIN_WINDOW_SCALE
        preloadManager?.reset()
        shrinkPooledPlayers(targetSize = 0)
        enforceVisibleWindowEviction(forceAggressive = true)
    }

    private companion object {
        /** Consecutive stalls tolerated before the window is halved. */
        const val REBUFFERS_BEFORE_DEGRADE = 3

        /** Floor for [windowScale]; below this preloading stops helping. */
        const val MIN_WINDOW_SCALE = 0.25
    }

    /**
     * Hands the current window to the preload manager.
     *
     * Coalesced onto the main looper so a fling that fires many viewport
     * updates results in one sync against the final position rather than one
     * per intermediate position.
     */
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
                scale = windowScale
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
            // Controllers created since the last visible-source update have not
            // been measured against a current window yet.
            val measurable = forceAggressive ||
                managed.createdAtVisibleGeneration != visibleGeneration
            outsideWindow && measurable
        }.keys.toList()

        for (controllerId in toEvict) {
            releaseController(controllerId, ReleaseReasonMessage.EVICTED)
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

    /**
     * Picks the controller furthest from the viewport, never choosing the
     * source a controller is about to be created for.
     */
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

    /**
     * Starts playback from preloaded media when the manager already has it.
     *
     * A preloaded MediaSource only works on a player built by the preload
     * manager's builder, which is why every player here comes from
     * [FeedPreloadManager.buildPlayer].
     */
    private fun obtainPlayerFor(source: RegisteredSource): ExoPlayer {
        val player = obtainReusablePlayer()
        val preloadedSource = preloadManager?.mediaSourceFor(source)
        if (preloadedSource != null) {
            player.setMediaSource(preloadedSource)
        } else {
            player.setMediaItem(MediaItem.fromUri(source.uri))
        }
        player.prepare()
        return player
    }

    private fun obtainReusablePlayer(): ExoPlayer {
        if (recycledPlayers.isNotEmpty()) {
            return recycledPlayers.removeFirst()
        }
        return preloadManager?.buildPlayer() ?: createFallbackPlayer()
    }

    private fun emitCurrentPlaybackState(controllerId: Int, player: ExoPlayer) {
        val status = when (player.playbackState) {
            Player.STATE_IDLE -> PlaybackStatusMessage.IDLE
            Player.STATE_BUFFERING -> PlaybackStatusMessage.BUFFERING
            Player.STATE_READY ->
                if (player.isPlaying) PlaybackStatusMessage.PLAYING else PlaybackStatusMessage.READY
            Player.STATE_ENDED -> PlaybackStatusMessage.COMPLETED
            else -> PlaybackStatusMessage.IDLE
        }
        onState(controllerId, status, null)
    }

    private fun playerListener(controllerId: Int, player: ExoPlayer): Player.Listener {
        return object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                val metrics = metricsByController[controllerId]
                when (playbackState) {
                    Player.STATE_IDLE -> onState(controllerId, PlaybackStatusMessage.IDLE, null)
                    Player.STATE_BUFFERING -> {
                        if (metrics?.hasBeenReady == true) {
                            metrics.rebufferCount += 1
                            noteRebuffer()
                            emitMetrics(controllerId)
                        }
                        onState(controllerId, PlaybackStatusMessage.BUFFERING, null)
                    }
                    Player.STATE_READY -> {
                        metrics?.hasBeenReady = true
                        noteSteadyPlayback()
                        emitMetrics(controllerId)
                        onState(
                            controllerId,
                            if (player.isPlaying) {
                                PlaybackStatusMessage.PLAYING
                            } else {
                                PlaybackStatusMessage.READY
                            },
                            null
                        )
                    }
                    Player.STATE_ENDED ->
                        onState(controllerId, PlaybackStatusMessage.COMPLETED, null)
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                onState(
                    controllerId,
                    if (isPlaying) PlaybackStatusMessage.PLAYING else PlaybackStatusMessage.PAUSED,
                    null
                )
            }

            override fun onPlayerError(error: PlaybackException) {
                onState(
                    controllerId,
                    PlaybackStatusMessage.ERROR,
                    PlaybackErrorMapper.map(error)
                )
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width <= 0 || videoSize.height <= 0) {
                    return
                }
                // Media3 applies rotation to the reported size itself on all
                // supported API levels, so nothing is left for the renderer.
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
                // Accumulated into a lifetime total so the value means the same
                // thing as the iOS access-log total.
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
        for ((controllerId, managed) in managedPlayers) {
            val player = managed.player
            if (player.playbackState == Player.STATE_IDLE) {
                continue
            }
            // Offscreen, idle players do not need per-tick position traffic.
            // A controller is interesting only if it is rendering somewhere or
            // actively playing.
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

    /**
     * Only reached if initialize() has not run yet; still cache-backed so the
     * two paths share storage.
     */
    private fun createFallbackPlayer(): ExoPlayer {
        val dataSourceFactory = MediaCache.createDataSourceFactory { uri -> headersFor(uri) }
        return ExoPlayer.Builder(appContext)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
            .build()
    }

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
