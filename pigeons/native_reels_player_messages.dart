import 'package:pigeon/pigeon.dart';

class InitializeRequest {
  InitializeRequest({
    required this.maxCachedPlayers,
    required this.preloadCount,
  });

  final int maxCachedPlayers;
  final int preloadCount;
}

class VideoSourceMessage {
  VideoSourceMessage({required this.url, required this.index});

  final String url;
  final int index;
}

class PreloadRequest {
  PreloadRequest({required this.sources});

  final List<VideoSourceMessage> sources;
}

class CreateControllerRequest {
  CreateControllerRequest({
    required this.url,
    required this.index,
    required this.autoPlay,
    required this.looping,
  });

  final String url;
  final int index;
  final bool autoPlay;
  final bool looping;
}

class ControllerRequest {
  ControllerRequest({required this.controllerId});

  final int controllerId;
}

class SeekRequest {
  SeekRequest({required this.controllerId, required this.positionMs});

  final int controllerId;
  final int positionMs;
}

class VisibleIndexRequest {
  VisibleIndexRequest({required this.index});

  final int index;
}

class AttachViewRequest {
  AttachViewRequest({required this.controllerId, required this.viewId});

  final int controllerId;
  final int viewId;
}

@HostApi()
abstract class NativeReelsPlayerHostApi {
  void initialize(InitializeRequest request);

  void preload(PreloadRequest request);

  int createController(CreateControllerRequest request);

  void disposeController(ControllerRequest request);

  void play(ControllerRequest request);

  void pause(ControllerRequest request);

  void seekTo(SeekRequest request);

  void setVisibleIndex(VisibleIndexRequest request);

  void clearCache();

  void attachView(AttachViewRequest request);

  void detachView(ControllerRequest request);

  void disposeAll();
}
