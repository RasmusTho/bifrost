import CoreFoundation
import Foundation

private final class ScreenAPIRejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
protocol ScreenControlProviding {
    func controls(for appIdentifier: String) async throws -> ScreenControlSnapshot
}

struct DurableScreenAcknowledgement: Equatable {
    let recordIdentifier: String
    let contentIdentity: String
    let bundleShape: String
}

@MainActor
protocol ScreenBundleShipping {
    func ship(_ entry: ScreenQueueEntry) async throws -> DurableScreenAcknowledgement
}

struct ScreenControlAPI: ScreenControlProviding, ScreenBundleShipping {
    enum APIError: LocalizedError {
        case invalidHubAddress
        case invalidAPIKey
        case nonPrivateHost(String)
        case invalidResponse
        case rejectedStatus(Int)
        case missingDurableAcknowledgement

        var errorDescription: String? {
            switch self {
            case .invalidHubAddress:
                "No valid Heimdal hub address is configured. Capture remains paused."
            case .invalidAPIKey:
                "The configured Heimdal API key is invalid. Capture remains paused."
            case let .nonPrivateHost(host):
                "Refusing to send screen captures to non-private host \(host)."
            case .invalidResponse:
                "The Heimdal hub response could not be read. Capture remains paused."
            case let .rejectedStatus(status):
                "The Heimdal hub returned HTTP \(status); the offline frame remains queued."
            case .missingDurableAcknowledgement:
                "The Heimdal hub did not return a durable screen acknowledgement. The frame remains queued."
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let apiKey: String?
    private static let redirectDelegate = ScreenAPIRejectRedirects()

    init(baseURL: URL, apiKey: String? = nil, session: URLSession = .shared) throws {
        guard let scheme = baseURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = baseURL.host, !host.isEmpty else {
            throw APIError.invalidHubAddress
        }
        guard Self.isPrivateHost(host) else { throw APIError.nonPrivateHost(host) }
        if let apiKey {
            let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty, !normalizedKey.contains("\r"), !normalizedKey.contains("\n") else {
                throw APIError.invalidAPIKey
            }
            self.apiKey = normalizedKey
        } else {
            self.apiKey = nil
        }
        self.baseURL = baseURL
        self.session = session
    }

    static func configured() throws -> ScreenControlAPI {
        let configuredAddress = ProcessInfo.processInfo.environment["HEIMDAL_SCREEN_HUB_URL"]
            ?? "http://127.0.0.1:8000"
        let configuredKey = ProcessInfo.processInfo.environment["HEIMDAL_SCREEN_API_KEY"]
        guard let url = URL(string: configuredAddress) else { throw APIError.invalidHubAddress }
        return try ScreenControlAPI(baseURL: url, apiKey: configuredKey)
    }

    func controls(for appIdentifier: String) async throws -> ScreenControlSnapshot {
        guard var components = URLComponents(
            url: endpoint("api/heimdal/screen/control"),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidHubAddress
        }
        components.queryItems = [URLQueryItem(name: "app_id", value: appIdentifier)]
        guard let url = components.url else { throw APIError.invalidHubAddress }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        setAuthentication(on: &request)
        let (data, response) = try await session.data(for: request, delegate: Self.redirectDelegate)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.rejectedStatus(http.statusCode) }
        return try ScreenControlSnapshot.decode(data, expectedApplication: appIdentifier)
    }

    func ship(_ entry: ScreenQueueEntry) async throws -> DurableScreenAcknowledgement {
        var request = URLRequest(url: endpoint("api/heimdal/screen/capture"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = entry.payload
        setAuthentication(on: &request)

        let (data, response) = try await session.data(for: request, delegate: Self.redirectDelegate)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.rejectedStatus(http.statusCode) }
        return try Self.decodeDurableAcknowledgement(data)
    }

    static func decodeDurableAcknowledgement(_ data: Data) throws -> DurableScreenAcknowledgement {
        guard let acknowledgement = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordIdentifier = Self.nonemptyString(acknowledgement["record_id"]),
              let contentIdentity = Self.nonemptyString(acknowledgement["content_identity"]),
              let bundleShape = acknowledgement["bundle_shape"] as? String,
              bundleShape == "raw_capture_bundle",
              Self.strictBoolean(acknowledgement["created"]) != nil,
              Self.strictBoolean(acknowledgement["observation_published"]) == false else {
            throw APIError.missingDurableAcknowledgement
        }
        return DurableScreenAcknowledgement(
            recordIdentifier: recordIdentifier,
            contentIdentity: contentIdentity,
            bundleShape: bundleShape
        )
    }

    static func isPrivateHost(_ host: String) -> Bool {
        let lowered = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lowered == "localhost" || lowered == "::1" || lowered == "0:0:0:0:0:0:0:1"
            || lowered.hasSuffix(".local") || lowered.hasSuffix(".internal") {
            return true
        }
        let components = lowered.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let octets = components.compactMap { component -> UInt8? in
            guard let octet = UInt8(component), String(octet) == String(component) else { return nil }
            return octet
        }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (172, 16...31), (169, 254), (100, 64...127):
            return true
        default:
            return false
        }
    }

    private func setAuthentication(on request: inout URLRequest) {
        guard let apiKey else { return }
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
    }

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
