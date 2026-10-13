import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The server-owned speech plan returned by Mimer Companion. The client must
/// show this normalized text and provenance before it asks the server to
/// synthesize or returns audio for playback.
public struct CompanionTTSSegment: Decodable, Equatable, Sendable {
    public let index: Int
    public let text: String
    public let language: String
    public let provider: String?
    public let voiceID: String?

    enum CodingKeys: String, CodingKey {
        case index, text, language, provider
        case voiceID = "voice_id"
    }
}

public struct CompanionTTSPlan: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let localOnly: Bool
    public let allowBrowserFallback: Bool
    public let allowCloudFallback: Bool
    public let normalizedText: String
    public let language: String
    public let provider: String
    public let voiceID: String
    public let providerAvailable: Bool
    public let providerReason: String?
    public let warnings: [String]
    public let cacheKey: String
    public let cached: Bool
    public let mixedLanguage: Bool
    public let segments: [CompanionTTSSegment]
    public let audioURL: String

    enum CodingKeys: String, CodingKey {
        case enabled, language, provider, warnings, cached, segments
        case localOnly = "local_only"
        case allowBrowserFallback = "allow_browser_fallback"
        case allowCloudFallback = "allow_cloud_fallback"
        case normalizedText = "normalized_text"
        case voiceID = "voice_id"
        case providerAvailable = "provider_available"
        case providerReason = "provider_reason"
        case cacheKey = "cache_key"
        case mixedLanguage = "mixed_language"
        case audioURL = "audio_url"
    }

    public var canRequestAudio: Bool {
        cached || (enabled && localOnly && !allowBrowserFallback && !allowCloudFallback && providerAvailable)
    }
}

/// The Companion synthesis receipt. Audio is fetched separately from the
/// server-owned cache URL after this receipt has been validated.
public struct CompanionTTSSynthesis: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let state: String
    public let cached: Bool
    public let cacheKey: String
    public let audioURL: String?
    public let contentType: String
    public let provider: String
    public let language: String
    public let voiceID: String
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case ok, state, cached, provider, language, reason
        case cacheKey = "cache_key"
        case audioURL = "audio_url"
        case contentType = "content_type"
        case voiceID = "voice_id"
    }
}

public struct CompanionTTSAudio: Sendable {
    public let receipt: CompanionTTSSynthesis
    public let data: Data

    public init(receipt: CompanionTTSSynthesis, data: Data) {
        self.receipt = receipt
        self.data = data
    }
}

public enum CompanionTTSClientError: LocalizedError, Equatable {
    case invalidBaseURL
    case untrustedHost(String)
    case untrustedAudioURL
    case invalidResponse
    case serverRejected(Int)
    case unavailable(String)
    case planChanged
    case invalidAudio

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Enter a valid local Companion address, such as http://192.168.1.20:8765."
        case let .untrustedHost(host):
            "Refusing to send note text to non-private host \(host)."
        case .untrustedAudioURL:
            "Companion returned an audio URL outside the configured local service."
        case .invalidResponse:
            "Companion returned a response that could not be read."
        case let .serverRejected(status):
            "Companion rejected the request (HTTP \(status))."
        case let .unavailable(reason):
            "Companion audio is unavailable: \(reason)."
        case .planChanged:
            "The Companion speech plan changed. Review the updated plan before playing it."
        case .invalidAudio:
            "Companion did not return a valid WAV audio file."
        }
    }
}

/// Minimal surface consumed by the read-aloud UI. Keeping the protocol small
/// makes the interaction deterministic in tests without a live Companion.
public protocol CompanionTTSServing: Sendable {
    func plan(text: String) async throws -> CompanionTTSPlan
    func synthesize(text: String, expecting cacheKey: String) async throws -> CompanionTTSAudio
}

/// Local/private-only client for the v1 Mimer Companion TTS contract.
public final class CompanionTTSClient: CompanionTTSServing, @unchecked Sendable {
    private struct RequestBody: Encodable {
        let text: String
    }

    private let baseURL: URL
    private let session: URLSession
    private let redirectDelegate: RejectRedirectDelegate

    public convenience init(baseURL: String) throws {
        try self.init(baseURL: baseURL, configuration: .ephemeral)
    }

    /// `configuration` exists for deterministic URLProtocol tests. The
    /// production session rejects HTTP redirects for all fixed contract routes.
    public init(baseURL: String, configuration: URLSessionConfiguration) throws {
        let normalizedURL = try Self.normalizedBaseURL(baseURL)
        self.baseURL = normalizedURL
        let redirectDelegate = RejectRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    public static func validate(baseURL: String) throws {
        _ = try normalizedBaseURL(baseURL)
    }

    private static func normalizedBaseURL(_ rawValue: String) throws -> URL {
        guard let components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.url != nil,
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw CompanionTTSClientError.invalidBaseURL
        }
        guard LocalServiceHostPolicy.isTrusted(host: host, scheme: scheme) else {
            throw CompanionTTSClientError.untrustedHost(host)
        }
        var normalized = components
        normalized.path = ""
        guard let normalizedURL = normalized.url else { throw CompanionTTSClientError.invalidBaseURL }
        return normalizedURL
    }

    public func plan(text: String) async throws -> CompanionTTSPlan {
        let data = try await post(path: "/api/companion/tts/plan", text: text)
        let plan = try Self.decoder.decode(CompanionTTSPlan.self, from: data)
        guard !plan.normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isCacheKey(plan.cacheKey),
              plan.localOnly,
              !plan.allowBrowserFallback,
              !plan.allowCloudFallback else {
            throw CompanionTTSClientError.invalidResponse
        }
        _ = try validatedAudioURL(plan.audioURL, cacheKey: plan.cacheKey)
        return plan
    }

    public func synthesize(text: String, expecting cacheKey: String) async throws -> CompanionTTSAudio {
        guard Self.isCacheKey(cacheKey) else { throw CompanionTTSClientError.invalidResponse }
        let data = try await post(path: "/api/companion/tts/synthesize", text: text)
        let receipt = try Self.decoder.decode(CompanionTTSSynthesis.self, from: data)
        guard receipt.cacheKey == cacheKey else { throw CompanionTTSClientError.planChanged }
        guard receipt.ok else { throw CompanionTTSClientError.unavailable(receipt.reason ?? receipt.state) }
        guard receipt.contentType.lowercased().hasPrefix("audio/wav"),
              let audioURLString = receipt.audioURL else {
            throw CompanionTTSClientError.invalidResponse
        }
        let audioURL = try validatedAudioURL(audioURLString, cacheKey: cacheKey)
        let (audioData, response) = try await session.data(from: audioURL)
        guard let http = response as? HTTPURLResponse else { throw CompanionTTSClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CompanionTTSClientError.serverRejected(http.statusCode)
        }
        guard audioData.count <= 25 * 1024 * 1024,
              Self.isWave(data: audioData),
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("audio/wav") == true else {
            throw CompanionTTSClientError.invalidAudio
        }
        return CompanionTTSAudio(receipt: receipt, data: audioData)
    }

    private func post(path: String, text: String) async throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompanionTTSClientError.invalidResponse
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.encoder.encode(RequestBody(text: text))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionTTSClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CompanionTTSClientError.serverRejected(http.statusCode)
        }
        return data
    }

    private func validatedAudioURL(_ rawURL: String, cacheKey: String) throws -> URL {
        guard Self.isCacheKey(cacheKey),
              let candidate = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL,
              Self.isSameOrigin(candidate, baseURL),
              candidate.path == "/api/companion/tts/audio/\(cacheKey).wav",
              candidate.query == nil,
              candidate.fragment == nil else {
            throw CompanionTTSClientError.untrustedAudioURL
        }
        return candidate
    }

    private static func isCacheKey(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isWave(data: Data) -> Bool {
        data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data[8..<12] == Data("WAVE".utf8)
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else { return false }
        return left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && left.port == right.port
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

/// v1 host policy from the Mimer client contract. This is intentionally a
/// hostname/IP allowlist; it is not an authentication mechanism.
public enum LocalServiceHostPolicy {
    public static func isTrusted(host rawHost: String, scheme: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal") {
            return true
        }
        if host.hasSuffix(".ts.net") { return scheme.lowercased() == "https" }
        if let bytes = ipv4Bytes(host) {
            return isTrustedIPv4(bytes)
        }
        if let bytes = ipv6Bytes(host) {
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
            if bytes[0] & 0xFE == 0xFC { return true } // ULA fc00::/7
            if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true } // link-local fe80::/10
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
                return isTrustedIPv4(Array(bytes[12..<16]))
            }
        }
        return false
    }

    private static func isTrustedIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (127, _), (10, _), (192, 168):
            return true
        case (172, 16...31), (169, 254), (100, 64...127):
            return true
        default:
            return false
        }
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        #if canImport(Darwin)
        var address = in_addr()
        let parsed = host.withCString { inet_pton(AF_INET, $0, &address) }
        guard parsed == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0.prefix(4)) }
        #else
        return nil
        #endif
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        #if canImport(Darwin)
        let addressWithoutZone = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var address = in6_addr()
        let parsed = addressWithoutZone.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0.prefix(16)) }
        #else
        return nil
        #endif
    }
}

final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Contract endpoints are fixed and redirects can change the route or
        // POST semantics (including plan → synthesis). Require direct replies.
        completionHandler(nil)
    }
}
