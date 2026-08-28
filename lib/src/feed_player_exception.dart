import 'controller_release.dart';

/// Thrown when a command targets a released native player.
///
/// Check [FeedController.isReleased] or await [FeedController.onReleased]
/// before issuing another command.
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
