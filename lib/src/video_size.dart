import 'messages.g.dart';

/// Decoded video dimensions before [rotationDegrees] is applied.
class VideoSize {
  const VideoSize({
    required this.width,
    required this.height,
    this.rotationDegrees = 0,
  });

  static const VideoSize zero = VideoSize(width: 0, height: 0);

  final int width;
  final int height;

  /// Clockwise rotation still to be applied, in degrees.
  final int rotationDegrees;

  bool get isKnown => width > 0 && height > 0;

  /// Width divided by height, accounting for a quarter-turn rotation.
  double get aspectRatio {
    if (!isKnown) {
      return 1;
    }
    final bool swapped = rotationDegrees == 90 || rotationDegrees == 270;
    return swapped ? height / width : width / height;
  }

  static VideoSize fromMessage(VideoSizeEvent event) => VideoSize(
    width: event.width,
    height: event.height,
    rotationDegrees: event.rotationDegrees,
  );

  @override
  bool operator ==(Object other) =>
      other is VideoSize &&
      other.width == width &&
      other.height == height &&
      other.rotationDegrees == rotationDegrees;

  @override
  int get hashCode => Object.hash(width, height, rotationDegrees);

  @override
  String toString() =>
      'VideoSize(${width}x$height'
      '${rotationDegrees == 0 ? '' : ', rotation: $rotationDegrees'})';
}
