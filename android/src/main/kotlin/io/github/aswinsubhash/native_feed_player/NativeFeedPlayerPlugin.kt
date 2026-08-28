package io.github.aswinsubhash.native_feed_player

import android.app.Activity
import android.app.Application
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import java.util.concurrent.atomic.AtomicInteger

class NativeFeedPlayerPlugin : FlutterPlugin, ComponentCallbacks2, NativeFeedPlayerHostApi {
    private companion object {
        private const val VIDEO_VIEW_TYPE = "native_feed_player/video_view"

        /** Process-wide IDs prevent collisions after engine reattachment. */
        private val controllerIdSeed = AtomicInteger(0)
    }

    private var appContext: Context? = null
    private var exoPlayerManager: ExoPlayerManager? = null
    private var binaryMessenger: BinaryMessenger? = null

    private val stateEvents = BufferedStreamHandler<PlaybackStateEvent>()
    private val positionEvents = BufferedStreamHandler<PositionEvent>()
    private val metricsEvents = BufferedStreamHandler<MetricsEvent>()
    private val videoSizeEvents = BufferedStreamHandler<VideoSizeEvent>()
    private val lifecycleEvents = BufferedStreamHandler<ControllerLifecycleEvent>()

    /** Started-activity count used for foreground playback state. */
    private var startedActivityCount = 0
    private var activityCallbacks: Application.ActivityLifecycleCallbacks? = null

    private val textureViewPool = TextureViewPool(maxPoolSize = 8)
    private val videoViews = PlatformViewRegistry<Int, NativeVideoPlatformView>()
    private val attachedControllerByViewId = mutableMapOf<Int, Int>()
    private var textureOutputs: TextureOutputRegistry? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        appContext?.registerComponentCallbacks(this)
        binaryMessenger = flutterPluginBinding.binaryMessenger
        textureOutputs = TextureOutputRegistry(flutterPluginBinding.textureRegistry)

        flutterPluginBinding.platformViewRegistry.registerViewFactory(
            VIDEO_VIEW_TYPE,
            NativeVideoViewFactory(
                textureViewPool = textureViewPool,
                onCreate = { viewId, view -> handleVideoViewCreated(viewId, view) },
                onDispose = { viewId, view -> handleVideoViewDisposed(viewId, view) }
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
        VideoSizeEventsStreamHandler.register(
            flutterPluginBinding.binaryMessenger,
            VideoSizeStreamAdapter(videoSizeEvents)
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
            onMetrics = { event -> metricsEvents.emit(event) },
            onVideoSize = { event -> videoSizeEvents.emit(event) }
        )

        registerActivityCallbacks(flutterPluginBinding.applicationContext)

        NativeFeedPlayerHostApi.setUp(
            binaryMessenger = flutterPluginBinding.binaryMessenger,
            api = this
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        unregisterActivityCallbacks()
        releaseTextureOutputs()
        textureOutputs = null
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
        releaseTextureOutputs()
        attachedControllerByViewId.clear()
        managerOrThrow().initialize(config)
        stateEvents.clearPending()
        positionEvents.clearPending()
        metricsEvents.clearPending()
        videoSizeEvents.clearPending()
        lifecycleEvents.clearPending()
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

    override fun setVolume(request: ControllerDoubleRequest) {
        managerOrThrow().setVolume(request.controllerId.toInt(), request.value)
    }

    override fun setMuted(request: ControllerFlagRequest) {
        managerOrThrow().setMuted(request.controllerId.toInt(), request.value)
    }

    override fun setPlaybackSpeed(request: ControllerDoubleRequest) {
        managerOrThrow().setPlaybackSpeed(request.controllerId.toInt(), request.value)
    }

    override fun setLooping(request: ControllerFlagRequest) {
        managerOrThrow().setLooping(request.controllerId.toInt(), request.value)
    }

    override fun setAudioPolicy(policy: AudioPolicyMessage) {
        managerOrThrow().applyAudioPolicy(policy)
    }

    override fun setVisibleSource(request: VisibleSourceRequest) {
        managerOrThrow().setVisibleSource(request.sourceId)
    }

    override fun evictCachedMedia(request: SourceIdsRequest) {
        managerOrThrow().evictCachedMedia(request.sourceIds)
    }

    override fun clearMediaCache() {
        managerOrThrow().clearMediaCache()
    }

    override fun cacheStatus(request: VisibleSourceRequest): CacheStatusMessage =
        managerOrThrow().cacheStatus(request.sourceId)

    override fun cacheUsageBytes(): Long = managerOrThrow().cacheUsageBytes()

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

    override fun attachTexture(request: ControllerRequest): Long {
        val controllerId = request.controllerId.toInt()
        val registry = textureOutputs
            ?: throw FlutterError("not_attached", "No texture registry available.", null)
        val manager = managerOrThrow()
        return registry.attach(controllerId) { surface ->
            manager.bindSurface(controllerId, surface)
        }
    }

    override fun detachTexture(request: ControllerRequest) {
        val controllerId = request.controllerId.toInt()
        val manager = exoPlayerManager
        textureOutputs?.detach(controllerId) { _ ->
            manager?.unbindSurface(controllerId)
        }
    }

    override fun disposeAll() {
        releaseTextureOutputs()
        managerOrThrow().disposeAll()
        attachedControllerByViewId.clear()
    }

    private fun releaseTextureOutputs() {
        val manager = exoPlayerManager
        textureOutputs?.clear { controllerId, _ -> manager?.unbindSurface(controllerId) }
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

    private fun registerActivityCallbacks(context: Context) {
        val application = context.applicationContext as? Application ?: return
        unregisterActivityCallbacks()

        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                startedActivityCount += 1
                if (startedActivityCount == 1) {
                    exoPlayerManager?.onAppForegrounded()
                }
            }

            override fun onActivityStopped(activity: Activity) {
                startedActivityCount = (startedActivityCount - 1).coerceAtLeast(0)
                if (startedActivityCount == 0) {
                    exoPlayerManager?.onAppBackgrounded()
                }
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        }
        application.registerActivityLifecycleCallbacks(callbacks)
        activityCallbacks = callbacks
    }

    private fun unregisterActivityCallbacks() {
        val application = appContext?.applicationContext as? Application
        activityCallbacks?.let { application?.unregisterActivityLifecycleCallbacks(it) }
        activityCallbacks = null
        startedActivityCount = 0
    }

    private fun managerOrThrow(): ExoPlayerManager {
        return exoPlayerManager
            ?: throw FlutterError(
                "not_attached",
                "NativeFeedPlayerPlugin is not attached to a Flutter engine.",
                null
            )
    }

    private fun handleVideoViewCreated(viewId: Int, view: NativeVideoPlatformView) {
        val previousControllerId = attachedControllerByViewId.remove(viewId)
        if (previousControllerId != null) {
            exoPlayerManager?.detachControllerFromView(previousControllerId)
        }
        videoViews.register(viewId, view)
    }

    private fun handleVideoViewDisposed(viewId: Int, view: NativeVideoPlatformView) {
        if (!videoViews.removeIfCurrent(viewId, view)) {
            textureViewPool.release(view.textureView)
            return
        }
        val controllerId = attachedControllerByViewId.remove(viewId)
        if (controllerId != null) {
            exoPlayerManager?.detachControllerFromView(controllerId)
        }
        textureViewPool.release(view.textureView)
    }
}

private fun FeedSourceMessage.toRegisteredSource(): RegisteredSource = RegisteredSource(
    id = id,
    uri = uri,
    rank = rank.toInt(),
    kind = kind,
    headers = headers
)
