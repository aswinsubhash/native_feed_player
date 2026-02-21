import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../native_reels_player_platform_interface.dart';
import 'video_controller.dart';

/// Platform view widget for rendering native video output.
class NativeVideoView extends StatefulWidget {
  const NativeVideoView({required this.controller, super.key});

  final VideoController controller;

  @override
  State<NativeVideoView> createState() => _NativeVideoViewState();
}

class _NativeVideoViewState extends State<NativeVideoView> {
  static const String _viewType = 'native_reels_player/video_view';
  int? _viewId;

  @override
  void didUpdateWidget(covariant NativeVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller.controllerId == widget.controller.controllerId) {
      return;
    }
    if (_viewId == null) {
      return;
    }
    unawaited(
      NativeReelsPlayerPlatform.instance.detachView(
        controllerId: oldWidget.controller.controllerId,
      ),
    );
    unawaited(
      NativeReelsPlayerPlatform.instance.attachView(
        controllerId: widget.controller.controllerId,
        viewId: _viewId!,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(
      NativeReelsPlayerPlatform.instance.detachView(
        controllerId: widget.controller.controllerId,
      ),
    );
    super.dispose();
  }

  Future<void> _onPlatformViewCreated(int viewId) async {
    _viewId = viewId;
    await NativeReelsPlayerPlatform.instance.attachView(
      controllerId: widget.controller.controllerId,
      viewId: viewId,
    );
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
      default:
        return const SizedBox.shrink();
    }
  }
}
