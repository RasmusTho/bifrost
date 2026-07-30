import Foundation

/// Outcome of `POST /api/heimdal/capture/media`.
///
/// The hub's contract is that no reachable failure surfaces as an unnamed 500,
/// because "never blind-retryable" only holds if the client always has an
/// `error` to branch on. This enum preserves that distinction rather than
/// collapsing everything into success/failure.
enum MediaAdmissionOutcome: Equatable {
    /// 2xx. Per the contract this is returned only after the raw-store write is
    /// durable *and* the admission event is committed, so the receipt is a
    /// statement of durable acceptance rather than of a successful HTTP call.
    case accepted(DurableAcceptanceReceipt)
    /// A `state: not_acknowledged` 500 family member (`raw_write_failed`,
    /// `admission_event_commit_failed`, `receipt_persistence_failed`,
    /// `raw_store_key_unavailable`, `media_cap_misconfigured`, `admission_failed`).
    /// Nothing was acknowledged and no receipt exists, so resending is safe and
    /// correct — the hub completes admission idempotently over any raw object a
    /// failed commit left behind.
    case notAcknowledged(errorCode: String)
    /// A named 4xx the client must not blind-retry: 415 `unsupported_media_kind`,
    /// 413 `media_too_large` / `sidecar_part_too_large`, 422 `multipart_invalid`
    /// and friends, 409 `consent_refused`. The original is still retained; the
    /// item waits with the reason recorded.
    case rejected(errorCode: String)
}

/// Outcome of `GET /api/heimdal/capture/receipts?capture_id=…`.
enum ReceiptQueryOutcome: Equatable {
    case admitted(DurableAcceptanceReceipt)
    /// The hub has no receipt for this identity. Only this answer licenses a resend.
    case unknown
    /// 503 `receipt_store_unavailable`. Deliberately distinct from `unknown`:
    /// the hub refuses to report a read failure as `unknown` precisely because
    /// `unknown` is an answer a client deletes originals against. The client
    /// must treat this as "no information" — neither release nor resend.
    case storeUnavailable
}

/// Transport seam for the CDLM-01 media ingress. Kept as a protocol so the
/// durability state machine is testable without a live hub, which matters here:
/// `KD-4384-RAWKEY` records that `HEIMDAL_RAW_STORE_KEY` is not yet provisioned
/// to the api process, so a live hub currently refuses every admission with a
/// named `raw_store_key_unavailable` / `not_acknowledged` 500.
protocol HeimdalMediaTransporting: Sendable {
    func admit(item: TransferOutboxItem) async throws -> MediaAdmissionOutcome
    func receipt(forCaptureID captureID: String) async throws -> ReceiptQueryOutcome
}

/// Production transport against a hub reachable over loopback, LAN, or tailnet.
///
/// Reachability failures are surfaced as thrown errors rather than as outcomes,
/// so the coordinator can distinguish "the hub said something" from "the hub
/// said nothing" — the former can change state, the latter never may.
struct HeimdalMediaAPITransport: HeimdalMediaTransporting {
    enum TransportError: LocalizedError {
        case hubNotConfigured
        case nonPrivateHost(String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .hubNotConfigured:
                "No Heimdal hub address is configured."
            case let .nonPrivateHost(host):
                "Refusing to transfer captures to non-private host \(host)."
            case .malformedResponse:
                "The hub's response could not be read."
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) throws {
        guard let host = baseURL.host else { throw TransportError.hubNotConfigured }
        guard Self.isPrivateHost(host) else { throw TransportError.nonPrivateHost(host) }
        self.baseURL = baseURL
        self.session = session
    }

    /// Loopback, RFC1918 LAN, link-local, CGNAT (tailnet `100.64/10`), and
    /// `.local`/`.internal` names only. The capture lane is explicitly not a
    /// public-internet upload path.
    static func isPrivateHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".local") || lowered.hasSuffix(".internal") { return true }
        let octets = lowered.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168):
            return true
        case (172, 16...31), (169, 254), (100, 64...127):
            return true
        default:
            return false
        }
    }

    func admit(item: TransferOutboxItem) async throws -> MediaAdmissionOutcome {
        let boundary = "heimdal.\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("api/heimdal/capture/media"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(for: item, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.malformedResponse }

        if (200..<300).contains(http.statusCode) {
            guard let receipt = try? Self.decoder.decode(DurableAcceptanceReceipt.self, from: data) else {
                // A 2xx whose body is not a receipt is a contract violation, not
                // an acknowledgement. Treat it as unacknowledged so the original
                // is retained and the transfer is retried.
                return .notAcknowledged(errorCode: "receipt_body_unreadable")
            }
            return .accepted(receipt)
        }

        let errorCode = Self.errorCode(in: data) ?? "http_\(http.statusCode)"
        // The 500 family is explicitly not-acknowledged and therefore safely
        // resendable; named 4xx rejections are not.
        return http.statusCode >= 500 ? .notAcknowledged(errorCode: errorCode) : .rejected(errorCode: errorCode)
    }

    func receipt(forCaptureID captureID: String) async throws -> ReceiptQueryOutcome {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/heimdal/capture/receipts"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "capture_id", value: CaptureIdentity.canonical(captureID))]
        guard let url = components?.url else { throw TransportError.malformedResponse }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw TransportError.malformedResponse }

        if http.statusCode == 503 { return .storeUnavailable }
        guard (200..<300).contains(http.statusCode) else {
            // Any other non-2xx is "no information", never `unknown`.
            return .storeUnavailable
        }
        if let receipt = try? Self.decoder.decode(DurableAcceptanceReceipt.self, from: data) {
            return .admitted(receipt)
        }
        if let state = Self.state(in: data), state == "admitted" {
            // Admitted without a readable receipt body is not something to
            // delete an original against.
            return .storeUnavailable
        }
        return .unknown
    }

    private func multipartBody(for item: TransferOutboxItem, boundary: String) throws -> Data {
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        appendField("capture_id", item.envelope.captureID)
        appendField("content_sha256", item.envelope.contentSHA256)
        appendField("kind", item.envelope.kind.rawValue)
        appendField("device_id", item.envelope.deviceID)
        appendField("captured_at", ISO8601DateFormatter().string(from: item.envelope.capturedAt))
        if !item.envelope.sessionRefs.isEmpty {
            appendField("session_refs", item.envelope.sessionRefs.joined(separator: ","))
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"media\"; filename=\"\(item.envelope.mediaFileName)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(try Data(contentsOf: item.mediaURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func errorCode(in data: Data) -> String? {
        stringField("error", in: data)
    }

    private static func state(in data: Data) -> String? {
        stringField("state", in: data)
    }

    private static func stringField(_ name: String, in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[name] as? String
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
