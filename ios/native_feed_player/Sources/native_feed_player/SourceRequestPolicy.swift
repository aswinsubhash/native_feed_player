import Foundation

/// Decides which network destinations may receive a source's headers.
///
/// Headers reach the source URL's own origin and explicitly trusted HTTPS
/// origins only. Redirect targets are evaluated individually, so a redirect
/// to any other origin carries none of the source headers.
struct SourceRequestPolicy {
  private struct Origin: Hashable {
    let scheme: String
    let host: String
    let port: Int
  }

  /// Source headers to apply; Range stays under the loader's control.
  let headers: [String: String]
  private let sourceOrigin: Origin?
  private let trusted: Set<Origin>

  init(sourceURI: String, headers: [String: String], trustedOrigins: [String]) {
    self.headers = MediaCacheIdentity.normalizedHeaders(headers).filter { $0.key != "range" }
    sourceOrigin = URL(string: sourceURI).flatMap(Self.origin(of:))
    trusted = Set(
      trustedOrigins
        .compactMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .compactMap(Self.origin(of:))
        .filter { $0.scheme == "https" }
    )
  }

  func allowsHeaders(for url: URL) -> Bool {
    guard let origin = Self.origin(of: url) else {
      return false
    }
    return origin == sourceOrigin || (origin.scheme == "https" && trusted.contains(origin))
  }

  /// Removes every source header, then restores them only when the request's
  /// destination is authorized.
  func apply(to request: inout URLRequest) {
    for name in headers.keys {
      request.setValue(nil, forHTTPHeaderField: name)
    }
    guard let url = request.url, allowsHeaders(for: url) else {
      return
    }
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
  }

  /// Canonical `scheme://host[:port]`, or nil when not an HTTP(S) origin.
  static func canonicalOrigin(_ value: String) -> String? {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
      let origin = origin(of: url)
    else {
      return nil
    }
    let host = origin.host.contains(":") ? "[\(origin.host)]" : origin.host
    let defaultPort = origin.scheme == "https" ? 443 : 80
    return "\(origin.scheme)://\(host)\(origin.port == defaultPort ? "" : ":\(origin.port)")"
  }

  private static func origin(of url: URL) -> Origin? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host?.lowercased(), !host.isEmpty
    else {
      return nil
    }
    let bareHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    return Origin(scheme: scheme, host: bareHost, port: url.port ?? (scheme == "https" ? 443 : 80))
  }
}
