/// Why a native controller stopped existing.
enum ControllerReleaseReason {
  /// The application called `dispose()` on the controller.
  disposed,

  /// The native scheduler reclaimed the controller because it fell outside
  /// the active window or exceeded the player budget.
  evicted,

  /// The native player failed unrecoverably and was torn down.
  error,

  /// The Flutter engine detached and all native players were released.
  engineDetached,
}

ControllerReleaseReason releaseReasonFromString(String? value) {
  switch (value) {
    case 'evicted':
      return ControllerReleaseReason.evicted;
    case 'error':
      return ControllerReleaseReason.error;
    case 'engine_detached':
      return ControllerReleaseReason.engineDetached;
    case 'disposed':
    default:
      return ControllerReleaseReason.disposed;
  }
}

/// Emitted whenever a native controller is released, for any reason.
///
/// The native side owns controller lifetime, so this event is the only
/// reliable signal that a controller handle has become dead.
class ControllerReleaseEvent {
  const ControllerReleaseEvent({
    required this.controllerId,
    required this.reason,
  });

  final int controllerId;
  final ControllerReleaseReason reason;

  @override
  String toString() =>
      'ControllerReleaseEvent(id: $controllerId, reason: ${reason.name})';
}
