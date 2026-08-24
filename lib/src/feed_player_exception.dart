import 'controller_release.dart';

/// Thrown when a controller command is issued after the native player backing
/// it has been released.
///
/// Native code can reclaim a controller on its own (window eviction, memory
/// pressure), so this is a normal condition that callers should handle rather
/// than a programming error alone. Check [VideoController.isReleased] or await
/// [VideoController.onReleased] to react before issuing commands.
class ControllerReleasedError extends StateError {
  ControllerReleasedError({required this.controllerId, required this.reason})
    : super(
        'Controller $controllerId was released (${reason.name}) and can no '
        'longer accept commands.',
      );

  final int controllerId;
  final ControllerReleaseReason reason;
}

/// Thrown when the plugin is used on a platform it does not implement.
class UnsupportedPlatformError extends UnsupportedError {
  UnsupportedPlatformError(String platformName)
    : super(
        'native_feed_player has no implementation for $platformName. '
        'Supported platforms are Android and iOS.',
      );
}
