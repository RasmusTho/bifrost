import Foundation
import Network
import XCTest
@testable import HeimdalMacObserver

@MainActor
final class ScreenControlAPITests: XCTestCase {
    private let appIdentifier = "com.example.Editor"
    private let apiKey = "unit-test-key-not-a-credential"

    func testPrivateIPv4ClassificationRejectsHostnameSuffixes() {
        XCTAssertTrue(ScreenControlAPI.isPrivateHost("127.0.0.1"))
        XCTAssertFalse(ScreenControlAPI.isPrivateHost("127.0.0.1.example.com"))
    }

    func testConfiguredAPIKeyIsSentWithControlsAndCaptureRequests() async throws {
        ScreenAPIURLProtocol.install { request in
            if request.httpMethod == "GET" {
                return ScreenAPIStubResponse(statusCode: 200, headers: [:], body: Self.validControls)
            }
            return ScreenAPIStubResponse(statusCode: 200, headers: [:], body: Self.validAcknowledgement)
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let api = try ScreenControlAPI(
            baseURL: URL(string: "http://127.0.0.1:8000")!,
            apiKey: apiKey,
            session: session
        )

        _ = try await api.controls(for: appIdentifier)
        let entry = ScreenQueueEntry(
            appIdentifier: appIdentifier,
            binding: ScreenControlBinding(vaultIdentifier: "vault-1", localInstanceIdentifier: "instance-1"),
            payload: Data("frame-payload".utf8)
        )
        _ = try await api.ship(entry)

        let requests = ScreenAPIURLProtocol.recordedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-API-Key") == apiKey })
        XCTAssertEqual(ScreenAPIURLProtocol.recordedBodies[1], entry.payload)
    }

    func testCaptureRedirectIsRejectedBeforeFrameCanBeForwarded() async throws {
        let server = try ScreenAPIRedirectServer()
        try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port?.rawValue)
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        let api = try ScreenControlAPI(
            baseURL: baseURL,
            apiKey: apiKey
        )
        let entry = ScreenQueueEntry(
            appIdentifier: appIdentifier,
            binding: ScreenControlBinding(vaultIdentifier: "vault-1", localInstanceIdentifier: "instance-1"),
            payload: Data("sensitive-frame-payload".utf8)
        )

        do {
            _ = try await api.ship(entry)
            XCTFail("A redirected capture request must be rejected.")
        } catch let error as ScreenControlAPI.APIError {
            XCTAssertEqual(
                error.localizedDescription,
                "The Heimdal hub returned HTTP 307; the offline frame remains queued."
            )
        }

        let requests = server.recordedRequests
        XCTAssertEqual(requests.count, 1)
        let sentData = try XCTUnwrap(requests.first)
        let sentRequest = try XCTUnwrap(String(bytes: sentData, encoding: .utf8))
        let sentPayload = try XCTUnwrap(String(bytes: entry.payload, encoding: .utf8))
        XCTAssertTrue(sentRequest.contains(sentPayload))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenAPIURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let validControls = Data(
        """
        {
          "app_id": "com.example.Editor",
          "state": "ready",
          "settings_state": "ok",
          "errors": [],
          "capture_permitted": true,
          "excluded": false,
          "consent_active": true,
          "vault_id": "vault-1",
          "local_instance_id": "instance-1",
          "controls": {
            "screen_paused": false,
            "screen_excluded_apps": [],
            "screen_excluded_scopes": [],
            "screen_scope_app_mapping": {},
            "screen_capture_cadence_seconds": 12.5,
            "screen_client_buffer_max": 100
          }
        }
        """.utf8
    )

    private static let validAcknowledgement = Data(
        """
        {
          "record_id": "record-1",
          "content_identity": "content-identity-1",
          "created": true,
          "bundle_shape": "raw_capture_bundle",
          "observation_published": false
        }
        """.utf8
    )
}

private class ScreenAPIURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> ScreenAPIStubResponse)?
    private static var requests: [URLRequest] = []
    private static var requestBodies: [Data?] = []

    static var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static var recordedBodies: [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return requestBodies
    }

    static func install(handler: @escaping (URLRequest) -> ScreenAPIStubResponse) {
        lock.lock()
        defer { lock.unlock() }
        requests = []
        requestBodies = []
        self.handler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.readBody(from: request)
        Self.lock.lock()
        let responseHandler = Self.handler
        Self.requests.append(request)
        Self.requestBodies.append(body)
        Self.lock.unlock()

        guard let responseHandler, let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let result = responseHandler(request)
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: result.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: result.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        var body = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private struct ScreenAPIStubResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

private final class ScreenAPIRedirectServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ScreenAPIRedirectServer")
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var requests: [Data] = []
    private(set) var port: NWEndpoint.Port?

    var recordedRequests: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    port = listener.port
                    startContinuation?.resume()
                    startContinuation = nil
                case let .failed(error):
                    startContinuation?.resume(throwing: error)
                    startContinuation = nil
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, accumulated: Data())
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            let request = accumulated + (data ?? Data())
            if Self.isComplete(request) {
                let count = record(request)
                respond(connection, requestNumber: count)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                receiveRequest(connection, accumulated: request)
            }
        }
    }

    private func respond(_ connection: NWConnection, requestNumber: Int) {
        let response: Data
        if requestNumber == 1, let port {
            let location = "http://127.0.0.1:\(port.rawValue)/redirected"
            let lines = [
                "HTTP/1.1 307 Temporary Redirect",
                "Location: \(location)",
                "Content-Length: 0",
                "Connection: close",
                "",
                ""
            ]
            response = Data(lines.joined(separator: "\r\n").utf8)
        } else {
            let body = """
            {
              "record_id": "record-1",
              "content_identity": "identity-1",
              "created": true,
              "bundle_shape": "raw_capture_bundle",
              "observation_published": false
            }
            """
            let lines = [
                "HTTP/1.1 200 OK",
                "Content-Type: application/json",
                "Content-Length: \(body.utf8.count)",
                "Connection: close",
                "",
                body
            ]
            response = Data(lines.joined(separator: "\r\n").utf8)
        }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func record(_ request: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return requests.count
    }

    private static func isComplete(_ request: Data) -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = request.range(of: separator) else { return false }
        let header = String(bytes: request[..<headerRange.lowerBound], encoding: .utf8) ?? ""
        let contentLength = header.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { $0.split(separator: ":", maxSplits: 1).last }
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        return request.count >= headerRange.upperBound + contentLength
    }
}
