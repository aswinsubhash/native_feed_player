import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'native_reels_player_platform_interface.dart';
import 'src/video_models.dart';
import 'src/video_playback_state.dart';

/// An implementation of [NativeReelsPlayerPlatform] that uses method channels.
class MethodChannelNativeReelsPlayer extends NativeReelsPlayerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('native_reels_player');

  @visibleForTesting
  final stateEventChannel = const EventChannel('native_reels_player/state');

  @visibleForTesting
  final positionEventChannel = const EventChannel(
    'native_reels_player/position',
  );

  late final Stream<Map<dynamic, dynamic>> _rawStateEvents = stateEventChannel
      .receiveBroadcastStream()
      .where((Object? event) => event is Map<dynamic, dynamic>)
      .cast<Map<dynamic, dynamic>>()
      .asBroadcastStream();

  late final Stream<Map<dynamic, dynamic>> _rawPositionEvents =
      positionEventChannel
          .receiveBroadcastStream()
          .where((Object? event) => event is Map<dynamic, dynamic>)
          .cast<Map<dynamic, dynamic>>()
          .asBroadcastStream();

  final Map<int, Stream<VideoPlaybackState>> _stateStreams =
      <int, Stream<VideoPlaybackState>>{};
  final Map<int, Stream<Duration>> _positionStreams = <int, Stream<Duration>>{};

  @override
  Future<void> initialize({required NativeReelsConfig config}) async {
    await methodChannel.invokeMethod<void>('initialize', config.toMap());
  }

  @override
  Future<void> preload(List<NativeVideoSource> sources) async {
    await methodChannel.invokeMethod<void>('preload', <String, Object?>{
      'sources': sources
          .map((NativeVideoSource source) => source.toMap())
          .toList(),
    });
  }

  @override
  Future<int> createController({
    required String url,
    required int index,
    required bool autoPlay,
    required bool looping,
  }) async {
    final int? id = await methodChannel.invokeMethod<int>(
      'createController',
      <String, Object?>{
        'url': url,
        'index': index,
        'autoPlay': autoPlay,
        'looping': looping,
      },
    );
    if (id == null) {
      throw StateError('Native createController returned null id.');
    }
    return id;
  }

  @override
  Future<void> disposeController(int controllerId) async {
    await methodChannel.invokeMethod<void>(
      'disposeController',
      <String, Object?>{'controllerId': controllerId},
    );
    _stateStreams.remove(controllerId);
    _positionStreams.remove(controllerId);
  }

  @override
  Future<void> play(int controllerId) async {
    await methodChannel.invokeMethod<void>('play', <String, Object?>{
      'controllerId': controllerId,
    });
  }

  @override
  Future<void> pause(int controllerId) async {
    await methodChannel.invokeMethod<void>('pause', <String, Object?>{
      'controllerId': controllerId,
    });
  }

  @override
  Future<void> seekTo(int controllerId, Duration position) async {
    await methodChannel.invokeMethod<void>('seekTo', <String, Object?>{
      'controllerId': controllerId,
      'positionMs': position.inMilliseconds,
    });
  }

  @override
  Stream<Duration> positionStream(int controllerId) {
    return _positionStreams.putIfAbsent(controllerId, () {
      return _rawPositionEvents
          .where(
            (Map<dynamic, dynamic> event) =>
                event['controllerId'] == controllerId,
          )
          .map((Map<dynamic, dynamic> event) {
            final int positionMs = _asInt(event['positionMs']);
            return Duration(milliseconds: positionMs);
          });
    });
  }

  @override
  Stream<VideoPlaybackState> stateStream(int controllerId) {
    return _stateStreams.putIfAbsent(controllerId, () {
      return _rawStateEvents
          .where(
            (Map<dynamic, dynamic> event) =>
                event['controllerId'] == controllerId,
          )
          .map((Map<dynamic, dynamic> event) {
            final String rawState = event['state']?.toString() ?? 'error';
            return playbackStateFromString(rawState);
          });
    });
  }

  @override
  Future<void> clearCache() async {
    await methodChannel.invokeMethod<void>('clearCache');
  }

  @override
  Future<void> setVisibleIndex(int index) async {
    await methodChannel.invokeMethod<void>('setVisibleIndex', <String, Object?>{
      'index': index,
    });
  }

  @override
  Future<void> dispose() async {
    await methodChannel.invokeMethod<void>('disposeAll');
    _stateStreams.clear();
    _positionStreams.clear();
  }

  int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return 0;
  }
}
