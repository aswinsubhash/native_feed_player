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
    this.cacheKey,
    this.trustedHeaderOrigins = const <String>[],
  });

  final String id;
  final String uri;

  /// Sent with this source's requests, including cache fills. iOS rejects HLS
  /// sources with custom headers; use signed URLs or cookies there.
  final Map<String, String> headers;
  final FeedMediaKind kind;

  /// Optional stable cache identity. When set, it replaces [uri] in the cache
  /// key so signed or expiring URLs (`?sig=`, `?expires=`) still share one
  /// cache entry. Headers remain part of the identity either way.
  ///
  /// Changing [cacheKey] changes the source's cache identity, so `setSources`
  /// releases and re-creates any live controller for it — the same treatment
  /// as a [uri] change.
  final String? cacheKey;

  /// Additional HTTPS origins (`https://cdn.example.com[:port]`) that may
  /// receive [headers]. Headers always reach the origin of [uri]; every other
  /// origin — HLS child playlists, segments, keys, and redirect targets —
  /// receives none of them unless listed here.
  ///
  /// Each entry is a bare origin: no path, query, fragment, credentials, or
  /// wildcards, and it never implies its subdomains, other ports, or plain
  /// HTTP. Configure this from trusted application code, never from feed data.
  final List<String> trustedHeaderOrigins;

  Set<String> get _originSet => <String>{
    for (final String origin in trustedHeaderOrigins)
      canonicalHeaderOrigin(origin) ?? origin,
  };

  @override
  bool operator ==(Object other) =>
      other is FeedSource &&
      other.id == id &&
      other.uri == uri &&
      other.kind == kind &&
      other.cacheKey == cacheKey &&
      mapEquals(other.headers, headers) &&
      setEquals(other._originSet, _originSet);

  @override
  int get hashCode => Object.hash(
    id,
    uri,
    kind,
    cacheKey,
    Object.hashAllUnordered(
      headers.entries.map(
        (MapEntry<String, String> entry) => Object.hash(entry.key, entry.value),
      ),
    ),
    Object.hashAllUnordered(_originSet),
  );

  @override
  String toString() {
    final int queryStart = uri.indexOf('?');
    final int fragmentStart = uri.indexOf('#', queryStart + 1);
    final String safeUri = queryStart == -1
        ? uri
        : '${uri.substring(0, queryStart)}'
              '${fragmentStart == -1 ? '' : uri.substring(fragmentStart)}';
    return 'FeedSource(id: $id, uri: $safeUri, kind: ${kind.name}'
        '${cacheKey == null ? '' : ', cacheKey: $cacheKey'})';
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
    final Uri? parsed = Uri.tryParse(uri);
    if (parsed == null || parsed.scheme.isEmpty) {
      throw ArgumentError.value(
        uri,
        'uri',
        'Must be an absolute URI with a scheme.',
      );
    }
    final Set<String> origins = <String>{};
    for (final String origin in trustedHeaderOrigins) {
      final String? canonical = canonicalHeaderOrigin(origin);
      if (canonical == null) {
        throw ArgumentError.value(
          origin,
          'trustedHeaderOrigins',
          'Must be an HTTPS origin such as https://cdn.example.com, without '
              'a path, query, fragment, credentials, or wildcard.',
        );
      }
      origins.add(canonical);
    }
    return FeedSourceMessage(
      id: id,
      uri: uri,
      rank: rank,
      kind: kind.toMessage(),
      headers: headers,
      cacheKey: cacheKey,
      trustedHeaderOrigins: origins.toList()..sort(),
    );
  }
}

/// Returns `https://host[:port]` in canonical form, or null when [origin] is
/// not a bare HTTPS origin.
@visibleForTesting
String? canonicalHeaderOrigin(String origin) {
  final String trimmed = origin.trim();
  if (trimmed.contains('*')) {
    return null;
  }
  final Uri? parsed = Uri.tryParse(trimmed);
  if (parsed == null ||
      parsed.scheme.toLowerCase() != 'https' ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.hasQuery ||
      parsed.hasFragment ||
      (parsed.path.isNotEmpty && parsed.path != '/')) {
    return null;
  }
  final String host = parsed.host.toLowerCase();
  final String authority = host.contains(':') ? '[$host]' : host;
  final bool explicitPort = parsed.hasPort && parsed.port != 443;
  return 'https://$authority${explicitPort ? ':${parsed.port}' : ''}';
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
