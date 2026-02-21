class NativeReelsConfig {
  const NativeReelsConfig({this.maxCachedPlayers = 5, this.preloadCount = 2});

  final int maxCachedPlayers;
  final int preloadCount;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'maxCachedPlayers': maxCachedPlayers,
      'preloadCount': preloadCount,
    };
  }
}

class NativeVideoSource {
  const NativeVideoSource({required this.url, required this.index});

  final String url;
  final int index;

  Map<String, Object?> toMap() {
    return <String, Object?>{'url': url, 'index': index};
  }
}
