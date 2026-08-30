import 'package:flutter/foundation.dart';

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

  /// Sent with this source's requests, including cache fills. iOS rejects HLS
  /// sources with custom headers; use signed URLs or cookies there.
  final Map<String, String> headers;
  final FeedMediaKind kind;

  @override
  bool operator ==(Object other) =>
      other is FeedSource &&
      other.id == id &&
      other.uri == uri &&
      other.kind == kind &&
      mapEquals(other.headers, headers);

  @override
  int get hashCode => Object.hash(
    id,
    uri,
    kind,
    Object.hashAllUnordered(
      headers.entries.map(
        (MapEntry<String, String> entry) => Object.hash(entry.key, entry.value),
      ),
    ),
  );

  @override
  String toString() {
    final int queryStart = uri.indexOf('?');
    final int fragmentStart = uri.indexOf('#', queryStart + 1);
    final String safeUri = queryStart == -1
        ? uri
        : '${uri.substring(0, queryStart)}'
              '${fragmentStart == -1 ? '' : uri.substring(fragmentStart)}';
    return 'FeedSource(id: $id, uri: $safeUri, kind: ${kind.name})';
  }
}

extension FeedSourceMessaging on FeedSource {
  FeedSourceMessage toMessage(int rank) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be empty.');
    }
    if (uri.trim().isEmpty) {
      throw ArgumentError.value(uri, 'uri', 'Must not be empty.');
    }
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
