import Foundation
import XCTest
@testable import YggdrasilCore

final class CompanionTTSClientTests: XCTestCase {
    override func tearDown() {
        CompanionTTSURLProtocol.handler = nil
        CompanionTTSURLProtocol.resetRecordedRequests()
        super.tearDown()
    }

    func testLocalServiceHostPolicyAllowsLocalLANAndTailnetOnly() throws {
        XCTAssertTrue(LocalServiceHostPolicy.isTrusted(host: "localhost", scheme: "http"))
        XCTAssertTrue(LocalServiceHostPolicy.isTrusted(host: "192.168.1.20", scheme: "http"))
        XCTAssertTrue(LocalServiceHostPolicy.isTrusted(host: "100.101.22.3", scheme: "http"))
        XCTAssertTrue(LocalServiceHostPolicy.isTrusted(host: "fd7a:115c:a1e0::1", scheme: "http"))
        XCTAssertTrue(LocalServiceHostPolicy.isTrusted(host: "device.tailnet.ts.net", scheme: "https"))
        XCTAssertFalse(LocalServiceHostPolicy.isTrusted(host: "device.tailnet.ts.net", scheme: "http"))
        XCTAssertFalse(LocalServiceHostPolicy.isTrusted(host: "example.com", scheme: "https"))

        XCTAssertNoThrow(try CompanionTTSClient.validate(baseURL: "http://192.168.1.20:8765"))
        XCTAssertThrowsError(try CompanionTTSClient.validate(baseURL: "https://example.com"))
        XCTAssertThrowsError(try CompanionTTSClient.validate(baseURL: "http://192.168.1.20/other"))
        XCTAssertThrowsError(try CompanionTTSClient.validate(baseURL: "http://user:secret@192.168.1.20"))
    }

    func testClientUsesPlanThenSynthesisThenSameOriginServerWAV() async throws {
        let key = String(repeating: "a", count: 64)
        let planData = try Self.planJSON(cacheKey: key)
        let synthesisData = try Self.synthesisJSON(cacheKey: key)
        CompanionTTSURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/companion/tts/plan":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                guard let body = Self.requestBody(request),
                      let object = try? JSONSerialization.jsonObject(with: body) as? [String: String] else {
                    XCTFail("Expected a JSON Companion request body.")
                    return CompanionTTSStubResponse(statusCode: 200, data: planData)
                }
                XCTAssertEqual(object, ["text": "A note"])
                return CompanionTTSStubResponse(statusCode: 200, data: planData)
            case "/api/companion/tts/synthesize":
                XCTAssertEqual(request.httpMethod, "POST")
                return CompanionTTSStubResponse(statusCode: 200, data: synthesisData)
            case "/api/companion/tts/audio/\(key).wav":
                XCTAssertEqual(request.httpMethod, "GET")
                return CompanionTTSStubResponse(statusCode: 200, data: Self.wavData(), contentType: "audio/wav")
            default:
                XCTFail("Unexpected Companion route: \(path)")
                return CompanionTTSStubResponse(statusCode: 500)
            }
        }

        let client = try Self.client()
        let plan = try await client.plan(text: "A note")
        XCTAssertEqual(plan.normalizedText, "A note")
        XCTAssertEqual(plan.cacheKey, key)
        XCTAssertTrue(plan.canRequestAudio)

        let result = try await client.synthesize(text: "A note", expecting: key)
        XCTAssertEqual(result.receipt.cacheKey, key)
        XCTAssertEqual(result.data, Self.wavData())
    }

    func testClientRejectsFallbackPlansMismatchedReceiptsAndExternalAudioURLs() async throws {
        let key = String(repeating: "a", count: 64)
        let fallbackData = try Self.planJSON(cacheKey: key, allowCloudFallback: true)
        CompanionTTSURLProtocol.handler = { request in
            if request.url?.path == "/api/companion/tts/plan" {
                return CompanionTTSStubResponse(statusCode: 200, data: fallbackData)
            }
            return CompanionTTSStubResponse(statusCode: 500)
        }
        let fallbackClient = try Self.client()
        do {
            _ = try await fallbackClient.plan(text: "A note")
            XCTFail("Expected cloud fallback posture to fail closed.")
        } catch let error as CompanionTTSClientError {
            XCTAssertEqual(error, .invalidResponse)
        }

        let externalURLData = try Self.planJSON(cacheKey: key, audioURL: "https://example.com/audio.wav")
        CompanionTTSURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/companion/tts/plan" {
                return CompanionTTSStubResponse(statusCode: 200, data: externalURLData)
            }
            return CompanionTTSStubResponse(statusCode: 500)
        }
        let externalAudioClient = try Self.client()
        do {
            _ = try await externalAudioClient.plan(text: "A note")
            XCTFail("Expected an external audio URL to fail closed.")
        } catch let error as CompanionTTSClientError {
            XCTAssertEqual(error, .untrustedAudioURL)
        }

        let currentPlanData = try Self.planJSON(cacheKey: key)
        let changedReceiptData = try Self.synthesisJSON(cacheKey: String(repeating: "b", count: 64))
        CompanionTTSURLProtocol.handler = { request in
            if request.url?.path == "/api/companion/tts/plan" {
                return CompanionTTSStubResponse(statusCode: 200, data: currentPlanData)
            }
            return CompanionTTSStubResponse(statusCode: 200, data: changedReceiptData)
        }
        let mismatchedClient = try Self.client()
        do {
            _ = try await mismatchedClient.synthesize(text: "A note", expecting: key)
            XCTFail("Expected a changed server plan to require review.")
        } catch let error as CompanionTTSClientError {
            XCTAssertEqual(error, .planChanged)
        }
    }

    func testProviderUnavailableIsReviewableButNotPlayableWithoutCache() async throws {
        let key = String(repeating: "a", count: 64)
        let unavailableData = try Self.planJSON(
            cacheKey: key,
            enabled: false,
            providerAvailable: false,
            cached: false
        )
        CompanionTTSURLProtocol.handler = { _ in
            CompanionTTSStubResponse(statusCode: 200, data: unavailableData)
        }
        let plan = try await Self.client().plan(text: "A note")
        XCTAssertFalse(plan.canRequestAudio)
        XCTAssertEqual(plan.providerReason, "provider_unavailable")
    }

    fileprivate static func client() throws -> CompanionTTSClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompanionTTSURLProtocol.self]
        return try CompanionTTSClient(baseURL: "http://127.0.0.1:8765", configuration: configuration)
    }

    fileprivate static func planJSON(
        cacheKey: String,
        audioURL: String? = nil,
        enabled: Bool = true,
        providerAvailable: Bool = true,
        cached: Bool = false,
        allowCloudFallback: Bool = false
    ) throws -> Data {
        let plan: [String: Any] = [
            "enabled": enabled,
            "local_only": true,
            "allow_browser_fallback": false,
            "allow_cloud_fallback": allowCloudFallback,
            "normalized_text": "A note",
            "language": "en",
            "provider": "piper",
            "voice_id": "en_US-amy-medium",
            "provider_available": providerAvailable,
            "provider_reason": providerAvailable ? (NSNull() as Any) : ("provider_unavailable" as Any),
            "warnings": [],
            "cache_key": cacheKey,
            "cached": cached,
            "mixed_language": false,
            "segments": [[
                "index": 0,
                "text": "A note",
                "language": "en",
                "provider": "piper",
                "voice_id": "en_US-amy-medium"
            ]],
            "audio_url": audioURL ?? "/api/companion/tts/audio/\(cacheKey).wav"
        ]
        return try JSONSerialization.data(withJSONObject: plan)
    }

    fileprivate static func synthesisJSON(cacheKey: String) throws -> Data {
        let receipt: [String: Any] = [
            "ok": true,
            "state": "generated",
            "cached": false,
            "cache_key": cacheKey,
            "audio_url": "/api/companion/tts/audio/\(cacheKey).wav",
            "content_type": "audio/wav",
            "provider": "piper",
            "language": "en",
            "voice_id": "en_US-amy-medium",
            "reason": NSNull()
        ]
        return try JSONSerialization.data(withJSONObject: receipt)
    }

    private static func wavData() -> Data {
        Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("WAVE".utf8) + Data(repeating: 0, count: 32)
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class CompanionTTSRedirectTests: XCTestCase {
    override func tearDown() {
        CompanionTTSURLProtocol.handler = nil
        CompanionTTSURLProtocol.resetRecordedRequests()
        super.tearDown()
    }

    func testClientRejectsPlanAndAudioRedirectResponses() async throws {
        let key = String(repeating: "a", count: 64)
        try await assertPlanRedirectDoesNotSynthesize()

        CompanionTTSURLProtocol.resetRecordedRequests()
        let planData = try CompanionTTSClientTests.planJSON(cacheKey: key)
        let synthesisData = try CompanionTTSClientTests.synthesisJSON(cacheKey: key)
        let otherKey = String(repeating: "b", count: 64)
        CompanionTTSURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/companion/tts/plan":
                return CompanionTTSStubResponse(statusCode: 200, data: planData)
            case "/api/companion/tts/synthesize":
                return CompanionTTSStubResponse(statusCode: 200, data: synthesisData)
            case "/api/companion/tts/audio/\(key).wav":
                return CompanionTTSStubResponse(
                    statusCode: 307,
                    headers: ["Location": "/api/companion/tts/audio/\(otherKey).wav"]
                )
            default:
                XCTFail("Unexpected route after redirect rejection: \(request.url?.path ?? "nil")")
                return CompanionTTSStubResponse(statusCode: 500)
            }
        }
        do {
            _ = try await CompanionTTSClientTests.client().synthesize(text: "A note", expecting: key)
            XCTFail("Expected the audio redirect to be rejected.")
        } catch {
            XCTAssertEqual(
                CompanionTTSURLProtocol.recordedRequests.compactMap { $0.url?.path },
                [
                    "/api/companion/tts/synthesize",
                    "/api/companion/tts/audio/\(key).wav"
                ],
                "Audio must not be fetched from a redirected cache key or route."
            )
        }
    }

    func testRedirectDelegateRejectsPlanAndAudioRedirectTargets() throws {
        let delegate = RejectRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let redirects = [
            (
                "http://127.0.0.1:8765/api/companion/tts/plan",
                "http://127.0.0.1:8765/api/companion/tts/synthesize"
            ),
            (
                "http://127.0.0.1:8765/api/companion/tts/audio/\(String(repeating: "a", count: 64)).wav",
                "https://example.com/audio.wav"
            )
        ]

        for (source, target) in redirects {
            let sourceURL = try XCTUnwrap(URL(string: source))
            let targetURL = try XCTUnwrap(URL(string: target))
            let task = session.dataTask(with: sourceURL)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: sourceURL,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target]
            ))
            let targetRequest = URLRequest(url: targetURL)
            var acceptedRequest: URLRequest? = targetRequest
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: targetRequest
            ) { acceptedRequest = $0 }
            XCTAssertNil(acceptedRequest, "Redirect from \(source) to \(target) must be rejected.")
            task.cancel()
        }
    }

    private func assertPlanRedirectDoesNotSynthesize() async throws {
        CompanionTTSURLProtocol.resetRecordedRequests()
        CompanionTTSURLProtocol.handler = { _ in
            CompanionTTSStubResponse(statusCode: 307, headers: ["Location": "/api/companion/tts/synthesize"])
        }
        do {
            _ = try await CompanionTTSClientTests.client().plan(text: "A note")
            XCTFail("Expected the plan redirect to be rejected.")
        } catch {
            XCTAssertEqual(
                CompanionTTSURLProtocol.recordedRequests.compactMap { $0.url?.path },
                ["/api/companion/tts/plan"],
                "A plan redirect must not turn the reviewed request into synthesis."
            )
        }
    }
}

// URLProtocol requires overriding these class methods, so `static` cannot be used here.
// swiftlint:disable static_over_final_class
private final class CompanionTTSURLProtocol: URLProtocol, @unchecked Sendable {
    typealias ResponseHandler = (URLRequest) -> CompanionTTSStubResponse

    private static let lock = NSLock()
    private static var storedHandler: ResponseHandler?
    private static var storedRequests: [URLRequest] = []

    static var handler: ResponseHandler? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    static var recordedRequests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    static func resetRecordedRequests() {
        lock.withLock { storedRequests = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.lock.withLock { Self.storedRequests.append(request) }
        let result = handler(request)
        guard let response = HTTPURLResponse(
                url: url,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: result.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
// swiftlint:enable static_over_final_class

private struct CompanionTTSStubResponse {
    let statusCode: Int
    let data: Data
    let headers: [String: String]

    init(
        statusCode: Int,
        data: Data = Data(),
        contentType: String? = nil,
        headers extraHeaders: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.data = data
        var responseHeaders = extraHeaders
        if let contentType { responseHeaders["Content-Type"] = contentType }
        headers = responseHeaders
    }
}
