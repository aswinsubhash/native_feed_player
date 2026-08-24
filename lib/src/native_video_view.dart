import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'video_controller.dart';
import 'video_size.dart';

/// Renders native video output for a [FeedController].
///
/// The native surface fills its box, so [fit] is applied by sizing the surface
/// against the reported [VideoSize] rather than by scaling pixels.
class NativeVideoView extends StatefulWidget {
  const NativeVideoView({
    required this.controller,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.backgroundColor = const Color(0xFF000000),
    super.key,
  });

  final FeedController controller;

  /// How the video is sized inside the widget. Feeds normally want
  /// [BoxFit.cover]; [BoxFit.contain] letterboxes instead of cropping.
  final BoxFit fit;

  /// Shown until the first frame is rendered, hiding the black flash between
  /// items.
  final Widget? placeholder;

  final Color backgroundColor;

  @override
  State<NativeVideoView> createState() => _NativeVideoViewState();
}

class _NativeVideoViewState extends State<NativeVideoView> {
  static const String _viewType = 'native_feed_player/video_view';

  int? _viewId;
  FeedController? _attachedController;
  StreamSubscription<VideoSize>? _videoSizeSub;
  VideoSize _videoSize = VideoSize.zero;
  bool _hasFirstFrame = false;

  @override
  void initState() {
    super.initState();
    _observe(widget.controller);
  }

  @override
  void didUpdateWidget(covariant NativeVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller.controllerId == widget.controller.controllerId) {
      return;
    }
    _observe(widget.controller);
    // The platform view may not exist yet. Attaching is retried from
    // _onPlatformViewCreated once it does, so the new controller is never left
    // permanently unbound.
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
            // Controller released before a frame appeared; the placeholder stays.
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
    await controller.platform.detachView(controllerId: controller.controllerId);
  }

  Future<void> _onPlatformViewCreated(int viewId) async {
    _viewId = viewId;
    await _attach(widget.controller, viewId);
  }

  Widget _buildPlatformView() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: _viewType,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: _viewType,
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
    Widget video = _buildPlatformView();

    // Until the size is known there is nothing to fit against, so the surface
    // just fills the box.
    if (_videoSize.isKnown) {
      video = FittedBox(
        fit: widget.fit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: _videoSize.width.toDouble(),
          height: _videoSize.height.toDouble(),
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
