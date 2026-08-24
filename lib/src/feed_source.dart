import 'messages.g.dart';

/// How a source should be loaded natively.
enum FeedMediaKind {
  /// Infer from the URI. Falls back to progressive when ambiguous.
  auto,

  /// A single downloadable file (mp4/mov). Fully cacheable on both platforms.
  progressive,

  /// HTTP Live Streaming. Adaptive, but byte-level disk caching is not
  /// available on iOS; see the caching notes in the README.
  hls,
}

/// One item in the feed.
///
/// [id] is owned by the caller and must stay stable for the life of the item.
/// Positions are used only to rank preload priority, so appending a page never
/// invalidates existing sources.
class FeedSource {
  const FeedSource({
    required this.id,
    required this.uri,
    this.headers = const <String, String>{},
    this.kind = FeedMediaKind.auto,
  });

  final String id;
  final String uri;

  /// Sent with every request for this source, including cache fills.
  final Map<String, String> headers;
  final FeedMediaKind kind;

  @override
  bool operator ==(Object other) =>
      other is FeedSource &&
      other.id == id &&
      other.uri == uri &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, uri, kind);

  @override
  String toString() => 'FeedSource(id: $id, uri: $uri, kind: ${kind.name})';
}

extension FeedSourceMessaging on FeedSource {
  FeedSourceMessage toMessage(int rank) {
    return FeedSourceMessage(
      id: id,
      uri: uri,
      rank: rank,
      kind: kind.toMessage(),
      headers: headers,
    );
  }
}

extension FeedMediaKindMessaging on FeedMediaKind {
  FeedMediaKindMessage toMessage() {
    switch (this) {
      case FeedMediaKind.auto:
        return FeedMediaKindMessage.auto;
      case FeedMediaKind.progressive:
        return FeedMediaKindMessage.progressive;
      case FeedMediaKind.hls:
        return FeedMediaKindMessage.hls;
    }
  }
}
