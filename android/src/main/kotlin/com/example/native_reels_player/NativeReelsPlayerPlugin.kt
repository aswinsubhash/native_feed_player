package com.example.native_reels_player

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** NativeReelsPlayerPlugin */
class NativeReelsPlayerPlugin : FlutterPlugin, MethodCallHandler, ComponentCallbacks2 {
    private lateinit var methodChannel: MethodChannel
    private lateinit var stateChannel: EventChannel
    private lateinit var positionChannel: EventChannel

    private var appContext: Context? = null
    private var stateSink: EventChannel.EventSink? = null
    private var positionSink: EventChannel.EventSink? = null
    private var exoPlayerManager: ExoPlayerManager? = null
    private var nextControllerId = 1

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        appContext?.registerComponentCallbacks(this)

        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "native_reels_player")
        stateChannel = EventChannel(flutterPluginBinding.binaryMessenger, "native_reels_player/state")
        positionChannel = EventChannel(flutterPluginBinding.binaryMessenger, "native_reels_player/position")

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
            }
        )

        methodChannel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        val manager = exoPlayerManager
        if (manager == null) {
            result.error(
                "not_attached",
                "NativeReelsPlayerPlugin is not attached to a Flutter engine.",
                null
            )
            return
        }

        when (call.method) {
            "initialize" -> {
                val args = call.args()
                val maxCachedPlayers = args.intValue("maxCachedPlayers", 5)
                val preloadCount = args.intValue("preloadCount", 2)
                manager.initialize(maxCachedPlayers = maxCachedPlayers, preloadCount = preloadCount)
                result.success(null)
            }

            "preload" -> {
                val args = call.args()
                val rawSources = args["sources"] as? List<*> ?: emptyList<Any?>()
                val sources = rawSources.mapNotNull { item -> item as? Map<*, *> }
                manager.preload(sources)
                result.success(null)
            }

            "createController" -> {
                val args = call.args()
                val url = args["url"] as? String
                if (url.isNullOrBlank()) {
                    result.error("invalid_url", "createController requires a non-empty URL.", null)
                    return
                }
                val autoPlay = args.booleanValue("autoPlay", false)
                val looping = args.booleanValue("looping", true)
                val index = args.intValue("index", -1)

                val controllerId = nextControllerId++
                manager.createController(
                    controllerId = controllerId,
                    url = url,
                    index = index,
                    autoPlay = autoPlay,
                    looping = looping
                )
                result.success(controllerId)
            }

            "disposeController" -> {
                val args = call.args()
                val controllerId = args.intValue("controllerId", -1)
                if (controllerId > 0) {
                    manager.disposeController(controllerId)
                }
                result.success(null)
            }

            "play" -> {
                val controllerId = call.args().intValue("controllerId", -1)
                if (controllerId > 0) {
                    manager.play(controllerId)
                }
                result.success(null)
            }

            "pause" -> {
                val controllerId = call.args().intValue("controllerId", -1)
                if (controllerId > 0) {
                    manager.pause(controllerId)
                }
                result.success(null)
            }

            "seekTo" -> {
                val args = call.args()
                val controllerId = args.intValue("controllerId", -1)
                val positionMs = args.longValue("positionMs", 0L)
                if (controllerId > 0) {
                    manager.seekTo(controllerId, positionMs)
                }
                result.success(null)
            }

            "setVisibleIndex" -> {
                val index = call.args().intValue("index", 0)
                manager.setVisibleIndex(index)
                result.success(null)
            }

            "clearCache" -> {
                manager.clearCache()
                result.success(null)
            }

            "disposeAll" -> {
                manager.disposeAll()
                result.success(null)
            }

            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext?.unregisterComponentCallbacks(this)
        appContext = null
        exoPlayerManager?.disposeAll()
        exoPlayerManager = null
        nextControllerId = 1
        stateSink = null
        positionSink = null
        methodChannel.setMethodCallHandler(null)
        stateChannel.setStreamHandler(null)
        positionChannel.setStreamHandler(null)
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

    private fun MethodCall.args(): Map<*, *> {
        return this.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
    }

    private fun Map<*, *>.intValue(key: String, defaultValue: Int): Int {
        return (this[key] as? Number)?.toInt() ?: defaultValue
    }

    private fun Map<*, *>.longValue(key: String, defaultValue: Long): Long {
        return (this[key] as? Number)?.toLong() ?: defaultValue
    }

    private fun Map<*, *>.booleanValue(key: String, defaultValue: Boolean): Boolean {
        return this[key] as? Boolean ?: defaultValue
    }
}
