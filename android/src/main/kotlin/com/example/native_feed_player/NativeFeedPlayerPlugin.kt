package com.example.native_feed_player

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.view.TextureView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import java.util.concurrent.atomic.AtomicInteger

/** NativeFeedPlayerPlugin */
class NativeFeedPlayerPlugin : FlutterPlugin, ComponentCallbacks2, NativeFeedPlayerHostApi {
    private companion object {
        private const val VIDEO_VIEW_TYPE = "native_feed_player/video_view"

        /**
         * Controller ids must stay unique for the life of the process, not the
         * life of one engine attachment. Restarting the counter on detach lets
         * a second engine (or a hot restart) mint ids that collide with handles
         * Dart still holds.
         */
        private val controllerIdSeed = AtomicInteger(0)
    }

    private var appContext: Context? = null
    private var exoPlayerManager: ExoPlayerManager? = null
    private var binaryMessenger: BinaryMessenger? = null

    private val stateEvents = BufferedStreamHandler<PlaybackStateEvent>()
    private val positionEvents = BufferedStreamHandler<PositionEvent>()
    private val metricsEvents = BufferedStreamHandler<MetricsEvent>()
    private val lifecycleEvents = BufferedStreamHandler<ControllerLifecycleEvent>()

    private val textureViewPool = TextureViewPool(maxPoolSize = 8)
    private val videoViews = mutableMapOf<Int, NativeVideoPlatformView>()
    private val attachedControllerByViewId = mutableMapOf<Int, Int>()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        appContext?.registerComponentCallbacks(this)
        binaryMessenger = flutterPluginBinding.binaryMessenger

        flutterPluginBinding.platformViewRegistry.registerViewFactory(
            VIDEO_VIEW_TYPE,
            NativeVideoViewFactory(
                textureViewPool = textureViewPool,
                onCreate = { viewId, view -> videoViews[viewId] = view },
                onDispose = { viewId, textureView -> handleVideoViewDisposed(viewId, textureView) }
            )
        )

        PlaybackStateEventsStreamHandler.register(
            flutterPluginBinding.binaryMessenger,
            PlaybackStateStreamAdapter(stateEvents)
        )
        PositionEventsStreamHandler.register(
            flutterPluginBinding.binaryMessenger,
            PositionStreamAdapter(positionEvents)
        )
        MetricsEventsStreamHandler.register(
            flutterPluginBinding.binaryMessenger,
            MetricsStreamAdapter(metricsEvents)
        )
        LifecycleEventsStreamHandler.register(
            flutterPluginBinding.binaryMessenger,
            LifecycleStreamAdapter(lifecycleEvents)
        )

        exoPlayerManager = ExoPlayerManager(
            context = flutterPluginBinding.applicationContext,
            onState = { controllerId, status, error ->
                stateEvents.emit(
                    PlaybackStateEvent(
                        controllerId = controllerId.toLong(),
                        status = status,
                        error = error
                    )
                )
            },
            onReleased = { controllerId, reason ->
                lifecycleEvents.emit(
                    ControllerLifecycleEvent(
                        controllerId = controllerId.toLong(),
                        reason = reason
                    )
                )
            },
            onPosition = { event -> positionEvents.emit(event) },
            onMetrics = { event -> metricsEvents.emit(event) }
        )

        NativeFeedPlayerHostApi.setUp(
            binaryMessenger = flutterPluginBinding.binaryMessenger,
            api = this
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext?.unregisterComponentCallbacks(this)
        appContext = null
        exoPlayerManager?.disposeAll()
        exoPlayerManager = null
        videoViews.clear()
        attachedControllerByViewId.clear()
        textureViewPool.clear()
        stateEvents.detach()
        positionEvents.detach()
        metricsEvents.detach()
        lifecycleEvents.detach()
        NativeFeedPlayerHostApi.setUp(binaryMessenger = binding.binaryMessenger, api = null)
        binaryMessenger = null
    }

    override fun initialize(config: FeedPlayerConfigMessage) {
        managerOrThrow().initialize(config)
    }

    override fun setSources(sources: List<FeedSourceMessage>) {
        managerOrThrow().setSources(sources.map { it.toRegisteredSource() })
    }

    override fun appendSources(sources: List<FeedSourceMessage>) {
        managerOrThrow().appendSources(sources.map { it.toRegisteredSource() })
    }

    override fun removeSources(request: SourceIdsRequest) {
        managerOrThrow().removeSources(request.sourceIds)
    }

    override fun createController(request: CreateControllerRequest): Long {
        if (request.sourceId.isBlank()) {
            throw FlutterError("invalid_source", "createController requires a source id.", null)
        }
        val controllerId = controllerIdSeed.incrementAndGet()
        managerOrThrow().createController(
            controllerId = controllerId,
            sourceId = request.sourceId,
            autoPlay = request.autoPlay,
            looping = request.looping
        )
        return controllerId.toLong()
    }

    override fun disposeController(request: ControllerRequest) {
        val controllerId = request.controllerId.toInt()
        if (controllerId > 0) {
            managerOrThrow().disposeController(controllerId)
        }
    }

    override fun play(request: ControllerRequest) {
        val controllerId = request.controllerId.toInt()
        if (controllerId > 0) {
            managerOrThrow().play(controllerId)
        }
    }

    override fun pause(request: ControllerRequest) {
        val controllerId = request.controllerId.toInt()
        if (controllerId > 0) {
            managerOrThrow().pause(controllerId)
        }
    }

    override fun seekTo(request: SeekRequest) {
        val controllerId = request.controllerId.toInt()
        if (controllerId > 0) {
            managerOrThrow().seekTo(controllerId, request.positionMs)
        }
    }

    override fun setVisibleSource(request: VisibleSourceRequest) {
        managerOrThrow().setVisibleSource(request.sourceId)
    }

    override fun evictCachedMedia(request: SourceIdsRequest) {
        // Wired to the disk cache in a later phase; preload state is dropped so
        // the next request re-fetches.
        managerOrThrow().removeSources(emptyList())
    }

    override fun clearMediaCache() {
        // No persistent cache yet; see docs/ARCHITECTURE.md for the roadmap.
    }

    override fun cacheStatus(request: VisibleSourceRequest): CacheStatusMessage {
        return CacheStatusMessage(
            sourceId = request.sourceId,
            cachedBytes = 0,
            totalBytes = 0,
            isComplete = false
        )
    }

    override fun cacheUsageBytes(): Long = 0

    override fun attachView(request: AttachViewRequest) {
        val controllerId = request.controllerId.toInt()
        val viewId = request.viewId.toInt()
        if (controllerId <= 0 || viewId < 0) {
            throw FlutterError(
                "invalid_attach",
                "attachView requires valid controllerId and viewId.",
                null
            )
        }

        val view = videoViews[viewId]
            ?: throw FlutterError("view_not_found", "No video view found for id=$viewId.", null)

        val manager = managerOrThrow()
        val previousController = attachedControllerByViewId[viewId]
        if (previousController != null && previousController != controllerId) {
            manager.detachControllerFromView(previousController)
        }
        attachedControllerByViewId[viewId] = controllerId
        manager.attachControllerToView(controllerId, view.textureView)
    }

    override fun detachView(request: ControllerRequest) {
        val controllerId = request.controllerId.toInt()
        if (controllerId <= 0) {
            return
        }
        val manager = managerOrThrow()
        manager.detachControllerFromView(controllerId)
        val staleViewIds = attachedControllerByViewId
            .filterValues { it == controllerId }
            .keys
            .toList()
        for (viewId in staleViewIds) {
            attachedControllerByViewId.remove(viewId)
        }
    }

    override fun disposeAll() {
        managerOrThrow().disposeAll()
        attachedControllerByViewId.clear()
    }

    override fun onTrimMemory(level: Int) {
        exoPlayerManager?.onTrimMemory(level)
    }

    @Deprecated("ComponentCallbacks2.onLowMemory is deprecated by the platform")
    override fun onLowMemory() {
        exoPlayerManager?.onLowMemory()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        // No-op: handled by the Flutter engine and ExoPlayer internally.
    }

    private fun managerOrThrow(): ExoPlayerManager {
        return exoPlayerManager
            ?: throw FlutterError(
                "not_attached",
                "NativeFeedPlayerPlugin is not attached to a Flutter engine.",
                null
            )
    }

    private fun handleVideoViewDisposed(viewId: Int, textureView: TextureView) {
        val controllerId = attachedControllerByViewId.remove(viewId)
        if (controllerId != null) {
            exoPlayerManager?.detachControllerFromView(controllerId)
        }
        videoViews.remove(viewId)
        textureViewPool.release(textureView)
    }
}

private fun FeedSourceMessage.toRegisteredSource(): RegisteredSource = RegisteredSource(
    id = id,
    uri = uri,
    rank = rank.toInt(),
    kind = kind,
    headers = headers
)
