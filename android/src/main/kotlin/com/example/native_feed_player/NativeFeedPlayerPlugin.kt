package com.example.native_feed_player

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.view.TextureView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

/** NativeFeedPlayerPlugin */
class NativeFeedPlayerPlugin : FlutterPlugin, ComponentCallbacks2, NativeFeedPlayerHostApi {
    private companion object {
        private const val VIDEO_VIEW_TYPE = "native_feed_player/video_view"
    }

    private lateinit var stateChannel: EventChannel
    private lateinit var positionChannel: EventChannel
    private lateinit var metricsChannel: EventChannel

    private var appContext: Context? = null
    private var stateSink: EventChannel.EventSink? = null
    private var positionSink: EventChannel.EventSink? = null
    private var metricsSink: EventChannel.EventSink? = null
    private var exoPlayerManager: ExoPlayerManager? = null
    private val textureViewPool = TextureViewPool(maxPoolSize = 8)
    private val videoViews = mutableMapOf<Int, NativeVideoPlatformView>()
    private val attachedControllerByViewId = mutableMapOf<Int, Int>()
    private var nextControllerId = 1

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        appContext?.registerComponentCallbacks(this)

        stateChannel = EventChannel(flutterPluginBinding.binaryMessenger, "native_feed_player/state")
        positionChannel = EventChannel(flutterPluginBinding.binaryMessenger, "native_feed_player/position")
        metricsChannel = EventChannel(flutterPluginBinding.binaryMessenger, "native_feed_player/metrics")

        flutterPluginBinding.platformViewRegistry.registerViewFactory(
            VIDEO_VIEW_TYPE,
            NativeVideoViewFactory(
                textureViewPool = textureViewPool,
                onCreate = { viewId, view ->
                    videoViews[viewId] = view
                },
                onDispose = { viewId, textureView ->
                    handleVideoViewDisposed(viewId, textureView)
                }
            )
        )

        stateChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    stateSink = events
                }

                override fun onCancel(arguments: Any?) {
                    stateSink = null
                }
            }
        )

        positionChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    positionSink = events
                }

                override fun onCancel(arguments: Any?) {
                    positionSink = null
                }
            }
        )

        metricsChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    metricsSink = events
                }

                override fun onCancel(arguments: Any?) {
                    metricsSink = null
                }
            }
        )

        exoPlayerManager = ExoPlayerManager(
            context = flutterPluginBinding.applicationContext,
            onState = { controllerId, state ->
                stateSink?.success(
                    mapOf(
                        "controllerId" to controllerId,
                        "state" to state
                    )
                )
            },
            onPosition = { controllerId, positionMs ->
                positionSink?.success(
                    mapOf(
                        "controllerId" to controllerId,
                        "positionMs" to positionMs
                    )
                )
            },
            onMetrics = { _, metrics ->
                metricsSink?.success(metrics)
            }
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
        nextControllerId = 1
        stateSink = null
        positionSink = null
        metricsSink = null
        NativeFeedPlayerHostApi.setUp(
            binaryMessenger = binding.binaryMessenger,
            api = null
        )
        stateChannel.setStreamHandler(null)
        positionChannel.setStreamHandler(null)
        metricsChannel.setStreamHandler(null)
    }

    override fun initialize(request: InitializeRequest) {
        managerOrThrow().initialize(
            maxCachedPlayers = request.maxCachedPlayers.toInt(),
            preloadCount = request.preloadCount.toInt()
        )
    }

    override fun preload(request: PreloadRequest) {
        val sources = request.sources.map { source ->
            mapOf(
                "index" to source.index.toInt(),
                "url" to source.url
            )
        }
        managerOrThrow().preload(sources)
    }

    override fun createController(request: CreateControllerRequest): Long {
        val url = request.url
        if (url.isBlank()) {
            throw FlutterError(
                "invalid_url",
                "createController requires a non-empty URL.",
                null
            )
        }

        val controllerId = nextControllerId++
        managerOrThrow().createController(
            controllerId = controllerId,
            url = url,
            index = request.index.toInt(),
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

    override fun setVisibleIndex(request: VisibleIndexRequest) {
        managerOrThrow().setVisibleIndex(request.index.toInt())
    }

    override fun clearCache() {
        managerOrThrow().clearCache()
    }

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
        if (controllerId > 0) {
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
    }

    override fun disposeAll() {
        managerOrThrow().disposeAll()
        attachedControllerByViewId.clear()
    }

    override fun onTrimMemory(level: Int) {
        exoPlayerManager?.onTrimMemory(level)
    }

    override fun onLowMemory() {
        exoPlayerManager?.onLowMemory()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        // No-op: handled by Flutter engine and ExoPlayer internally.
    }

    private fun managerOrThrow(): ExoPlayerManager {
        return exoPlayerManager
            ?: throw FlutterError(
                "not_attached",
                "NativeFeedPlayerPlugin is not attached to a Flutter engine.",
                null
            )
    }

    private fun handleVideoViewDisposed(
        viewId: Int,
        textureView: TextureView
    ) {
        val controllerId = attachedControllerByViewId.remove(viewId)
        if (controllerId != null) {
            exoPlayerManager?.detachControllerFromView(controllerId)
        }
        videoViews.remove(viewId)
        textureViewPool.release(textureView)
    }
}
