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
  FeedController? _attachedController;
  StreamSubscription<VideoSize>? _videoSizeSub;
  VideoSize _videoSize = VideoSize.zero;
  bool _hasFirstFrame = false;

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
      unawaited(_attachTexture(widget.controller));
    }
  }

  @override
  void didUpdateWidget(covariant NativeVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller.controllerId == widget.controller.controllerId) {
      return;
    }
    _observe(widget.controller);
    if (_usesTexture) {
      _textureId = null;
      unawaited(
        _detach(
          oldWidget.controller,
        ).then((_) => _attachTexture(widget.controller)),
      );
      return;
    }
    // Attach after the platform view is created.
    unawaited(_rebind(previous: oldWidget.controller));
  }

  @override
  void dispose() {
    unawaited(_videoSizeSub?.cancel());
    final FeedController? attached = _attachedController;
    if (attached != null) {
      unawaited(_detach(attached));
    }
    super.dispose();
  }

  void _observe(FeedController controller) {
    unawaited(_videoSizeSub?.cancel());
    _videoSize = VideoSize.zero;
    _hasFirstFrame = false;

    _videoSizeSub = controller.videoSizeStream.listen((VideoSize size) {
      if (!mounted) {
        return;
      }
      setState(() => _videoSize = size);
    });

    unawaited(
      controller.firstFrameRendered
          .then((_) {
            if (mounted && identical(widget.controller, controller)) {
              setState(() => _hasFirstFrame = true);
            }
          })
          .catchError((_) {
            // Preserve the placeholder after a pre-frame release.
          }),
    );
  }

  Future<void> _rebind({FeedController? previous}) async {
    final int? viewId = _viewId;
    if (previous != null && identical(_attachedController, previous)) {
      await _detach(previous);
    }
    if (viewId == null) {
      return;
    }
    await _attach(widget.controller, viewId);
  }

  Future<void> _attach(FeedController controller, int viewId) async {
    if (controller.isReleased) {
      return;
    }
    _attachedController = controller;
    await controller.platform.attachView(
      controllerId: controller.controllerId,
      viewId: viewId,
    );
  }

  Future<void> _detach(FeedController controller) async {
    if (identical(_attachedController, controller)) {
      _attachedController = null;
    }
    if (_usesTexture) {
      await controller.platform.detachTexture(controller.controllerId);
      return;
    }
    await controller.platform.detachView(controllerId: controller.controllerId);
  }

  Future<void> _attachTexture(FeedController controller) async {
    if (controller.isReleased) {
      return;
    }
    _attachedController = controller;
    final int textureId = await controller.platform.attachTexture(
      controller.controllerId,
    );
    if (!mounted || !identical(widget.controller, controller)) {
      return;
    }
    setState(() => _textureId = textureId);
  }

  Future<void> _onPlatformViewCreated(int viewId) async {
    _viewId = viewId;
    await _attach(widget.controller, viewId);
  }

  Widget _buildOutput() {
    if (_usesTexture) {
      final int? textureId = _textureId;
      return textureId == null
          ? const SizedBox.shrink()
          : Texture(textureId: textureId);
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: _viewType,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
        );
      case TargetPlatform.iOS:
        return UiKitView(
          key: ValueKey<BoxFit>(_effectiveFit),
          viewType: _viewType,
          creationParams: <String, Object>{'fit': _effectiveFit.name},
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
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
