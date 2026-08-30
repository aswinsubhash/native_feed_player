import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'feed_player_config.dart';
import 'video_controller.dart';
import 'video_size.dart';

/// Renders a [FeedController] into a platform view or Flutter texture.
class NativeVideoView extends StatefulWidget {
  const NativeVideoView({
    required this.controller,
    this.renderMode = RenderMode.platformView,
    this.fit,
    this.placeholder,
    this.backgroundColor = const Color(0xFF000000),
    super.key,
  });

  final FeedController controller;

  /// Must match the player's configured [RenderMode].
  final RenderMode renderMode;

  /// Overrides adaptive sizing. By default, portrait and square videos use
  /// [BoxFit.cover], while landscape videos use [BoxFit.contain].
  final BoxFit? fit;

  /// Displayed until the first frame is rendered.
  final Widget? placeholder;

  final Color backgroundColor;

  @override
  State<NativeVideoView> createState() => _NativeVideoViewState();
}

class _NativeVideoViewState extends State<NativeVideoView> {
  static const String _viewType = 'native_feed_player/video_view';

  int? _viewId;
  int? _textureId;
  int? _attachedViewId;
  FeedController? _attachedController;
  RenderMode? _attachedMode;
  StreamSubscription<VideoSize>? _videoSizeSub;
  Future<void> _attachmentQueue = Future<void>.value();
  VideoSize _videoSize = VideoSize.zero;
  bool _hasFirstFrame = false;
  bool _disposed = false;
  int _generation = 0;
  int _observationGeneration = 0;

  bool get _usesTexture => widget.renderMode == RenderMode.texture;

  BoxFit get _effectiveFit =>
      widget.fit ??
      (_videoSize.aspectRatio > 1 ? BoxFit.contain : BoxFit.cover);

  bool get _hasQuarterTurn =>
      _videoSize.rotationDegrees == 90 || _videoSize.rotationDegrees == 270;

  @override
  void initState() {
    super.initState();
    _observe(widget.controller);
    if (_usesTexture) {
      _scheduleReconcile();
    }
  }

  @override
  void didUpdateWidget(covariant NativeVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool controllerChanged = !identical(
      oldWidget.controller,
      widget.controller,
    );
    final bool modeChanged = oldWidget.renderMode != widget.renderMode;
    if (!controllerChanged && !modeChanged) {
      return;
    }
    _generation += 1;
    _textureId = null;
    if (modeChanged) {
      _viewId = null;
    }
    if (controllerChanged) {
      _observe(widget.controller);
    }
    _scheduleReconcile();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    _observationGeneration += 1;
    _textureId = null;
    final Future<void>? cancellation = _videoSizeSub?.cancel();
    if (cancellation != null) {
      unawaited(
        cancellation.catchError((Object error, StackTrace stackTrace) {
          _reportAsyncError(error, stackTrace, 'cancelling video size updates');
        }),
      );
    }
    _videoSizeSub = null;
    _enqueueAttachment(_detachCurrent);
    super.dispose();
  }

  void _observe(FeedController controller) {
    final int observation = ++_observationGeneration;
    final Future<void>? cancellation = _videoSizeSub?.cancel();
    if (cancellation != null) {
      unawaited(
        cancellation.catchError((Object error, StackTrace stackTrace) {
          _reportAsyncError(error, stackTrace, 'cancelling video size updates');
        }),
      );
    }
    _videoSize = VideoSize.zero;
    _hasFirstFrame = false;

    _videoSizeSub = controller.videoSizeStream.listen(
      (VideoSize size) {
        if (!_isObserved(controller, observation)) {
          return;
        }
        setState(() => _videoSize = size);
      },
      onError: (Object error, StackTrace stackTrace) {
        _reportAsyncError(error, stackTrace, 'observing video size');
      },
    );

    unawaited(
      controller.firstFrameRendered.then<void>(
        (_) {
          if (_isObserved(controller, observation)) {
            setState(() => _hasFirstFrame = true);
          }
        },
        onError: (Object _, StackTrace _) {
          // Preserve the placeholder after a pre-frame release.
        },
      ),
    );
    unawaited(
      controller.onReleased.then((_) {
        if (_isObserved(controller, observation)) {
          _scheduleReconcile();
        }
      }),
    );
  }

  bool _isObserved(FeedController controller, int observation) =>
      mounted &&
      !_disposed &&
      observation == _observationGeneration &&
      identical(widget.controller, controller);

  void _scheduleReconcile() {
    final int generation = _generation;
    final FeedController controller = widget.controller;
    final RenderMode mode = widget.renderMode;
    final int? viewId = mode == RenderMode.platformView ? _viewId : null;
    _enqueueAttachment(
      () => _reconcile(
        generation: generation,
        controller: controller,
        mode: mode,
        viewId: viewId,
      ),
    );
  }

  void _enqueueAttachment(Future<void> Function() operation) {
    _attachmentQueue = _attachmentQueue.then((_) => operation()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _reportAsyncError(error, stackTrace, 'updating the video attachment');
    });
  }

  Future<void> _reconcile({
    required int generation,
    required FeedController controller,
    required RenderMode mode,
    required int? viewId,
  }) async {
    final bool attachmentMatches =
        identical(_attachedController, controller) &&
        _attachedMode == mode &&
        (mode == RenderMode.texture || _attachedViewId == viewId);
    if (!attachmentMatches || controller.isReleased) {
      await _detachCurrent();
    } else {
      return;
    }

    if (!_isCurrent(generation, controller, mode, viewId)) {
      return;
    }

    if (mode == RenderMode.texture) {
      final int textureId = await controller.platform.attachTexture(
        controller.controllerId,
      );
      if (!_isCurrent(generation, controller, mode, viewId)) {
        await controller.platform.detachTexture(controller.controllerId);
        return;
      }
      _attachedController = controller;
      _attachedMode = mode;
      _attachedViewId = null;
      setState(() => _textureId = textureId);
      return;
    }

    if (viewId == null) {
      // Attach after the platform view is created.
      return;
    }
    await controller.platform.attachView(
      controllerId: controller.controllerId,
      viewId: viewId,
    );
    if (!_isCurrent(generation, controller, mode, viewId)) {
      await controller.platform.detachView(
        controllerId: controller.controllerId,
      );
      return;
    }
    _attachedController = controller;
    _attachedMode = mode;
    _attachedViewId = viewId;
  }

  bool _isCurrent(
    int generation,
    FeedController controller,
    RenderMode mode,
    int? viewId,
  ) =>
      mounted &&
      !_disposed &&
      generation == _generation &&
      identical(widget.controller, controller) &&
      widget.renderMode == mode &&
      !controller.isReleased &&
      (mode == RenderMode.texture || _viewId == viewId);

  Future<void> _detachCurrent() async {
    final FeedController? controller = _attachedController;
    final RenderMode? mode = _attachedMode;
    if (controller == null || mode == null) {
      return;
    }
    if (mode == RenderMode.texture) {
      await controller.platform.detachTexture(controller.controllerId);
    } else {
      await controller.platform.detachView(
        controllerId: controller.controllerId,
      );
    }
    if (identical(_attachedController, controller) && _attachedMode == mode) {
      _attachedController = null;
      _attachedMode = null;
      _attachedViewId = null;
    }
  }

  void _onPlatformViewCreated(
    int viewId,
    int generation,
    FeedController controller,
  ) {
    if (!mounted ||
        _disposed ||
        generation != _generation ||
        !identical(widget.controller, controller) ||
        widget.renderMode != RenderMode.platformView ||
        controller.isReleased) {
      return;
    }
    _generation += 1;
    _viewId = viewId;
    _scheduleReconcile();
  }

  void _reportAsyncError(
    Object error,
    StackTrace stackTrace,
    String operation,
  ) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'native_feed_player',
        context: ErrorDescription('while $operation'),
      ),
    );
  }

  Widget _buildOutput() {
    if (_usesTexture) {
      final int? textureId = _textureId;
      return textureId == null
          ? const SizedBox.shrink()
          : Texture(textureId: textureId);
    }

    final int generation = _generation;
    final FeedController controller = widget.controller;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: _viewType,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: (int viewId) =>
              _onPlatformViewCreated(viewId, generation, controller),
        );
      case TargetPlatform.iOS:
        return UiKitView(
          key: ValueKey<BoxFit>(_effectiveFit),
          viewType: _viewType,
          creationParams: <String, Object>{'fit': _effectiveFit.name},
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: (int viewId) =>
              _onPlatformViewCreated(viewId, generation, controller),
        );
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget video = _buildOutput();

    // Fill the bounds until dimensions are available.
    if (_videoSize.isKnown) {
      video = FittedBox(
        fit: _effectiveFit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: (_hasQuarterTurn ? _videoSize.height : _videoSize.width)
              .toDouble(),
          height: (_hasQuarterTurn ? _videoSize.width : _videoSize.height)
              .toDouble(),
          child: video,
        ),
      );
    }

    return ColoredBox(
      color: widget.backgroundColor,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          video,
          if (!_hasFirstFrame && widget.placeholder != null)
            widget.placeholder!,
        ],
      ),
    );
  }
}
