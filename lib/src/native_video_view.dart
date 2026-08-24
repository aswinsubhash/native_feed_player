import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'video_controller.dart';

/// Platform view widget for rendering native video output.
class NativeVideoView extends StatefulWidget {
  const NativeVideoView({required this.controller, super.key});

  final VideoController controller;

  @override
  State<NativeVideoView> createState() => _NativeVideoViewState();
}

class _NativeVideoViewState extends State<NativeVideoView> {
  static const String _viewType = 'native_feed_player/video_view';

  int? _viewId;
  VideoController? _attachedController;

  @override
  void didUpdateWidget(covariant NativeVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller.controllerId == widget.controller.controllerId) {
      return;
    }
    // The platform view may not exist yet. Attaching is retried from
    // _onPlatformViewCreated once it does, so the new controller is never
    // left permanently unbound.
    unawaited(_rebind(previous: oldWidget.controller));
  }

  @override
  void dispose() {
    final VideoController? attached = _attachedController;
    if (attached != null) {
      unawaited(_detach(attached));
    }
    super.dispose();
  }

  Future<void> _rebind({VideoController? previous}) async {
    final int? viewId = _viewId;
    if (previous != null && identical(_attachedController, previous)) {
      await _detach(previous);
    }
    if (viewId == null) {
      return;
    }
    await _attach(widget.controller, viewId);
  }

  Future<void> _attach(VideoController controller, int viewId) async {
    if (controller.isReleased) {
      return;
    }
    _attachedController = controller;
    await controller.platform.attachView(
      controllerId: controller.controllerId,
      viewId: viewId,
    );
  }

  Future<void> _detach(VideoController controller) async {
    if (identical(_attachedController, controller)) {
      _attachedController = null;
    }
    await controller.platform.detachView(controllerId: controller.controllerId);
  }

  Future<void> _onPlatformViewCreated(int viewId) async {
    _viewId = viewId;
    await _attach(widget.controller, viewId);
  }

  @override
  Widget build(BuildContext context) {
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
}
