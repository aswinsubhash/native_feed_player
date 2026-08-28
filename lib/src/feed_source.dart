import 'messages.g.dart';

/// How a source should be loaded natively.
enum FeedMediaKind {
  /// Infer from the URI. Falls back to progressive when ambiguous.
  auto,

  /// A single downloadable file (mp4/mov). Fully cacheable on both platforms.
  progressive,

  /// HTTP Live Streaming. iOS does not provide byte-level disk caching.
  hls,
}

/// A media source identified by a caller-defined stable [id].
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
