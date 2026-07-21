import Foundation

struct WatchRelayCaptureMetadata: Codable, Equatable {
    static let transferKey = "heimdal_capture_metadata_v1"

    let recordedStartAt: Date
    let recordedEndAt: Date
    let timezone: String
    let interruptions: Int

    func transferMetadata() throws -> [String: Any] {
        [Self.transferKey: try encodedData()]
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(transferMetadata: [String: Any]?) -> WatchRelayCaptureMetadata? {
        guard let bytes = transferMetadata?[transferKey] as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metadata = try? decoder.decode(Self.self, from: bytes),
              metadata.recordedEndAt >= metadata.recordedStartAt,
              metadata.interruptions >= 0,
              !metadata.timezone.isEmpty else { return nil }
        return metadata
    }
}

struct WatchRelayMetadataStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(_ metadata: WatchRelayCaptureMetadata, for audioURL: URL) throws {
        try metadata.encodedData().write(to: metadataURL(for: audioURL), options: .atomic)
    }

    func read(for audioURL: URL) -> WatchRelayCaptureMetadata? {
        guard let bytes = try? Data(contentsOf: metadataURL(for: audioURL)) else { return nil }
        return WatchRelayCaptureMetadata.decode(
            transferMetadata: [WatchRelayCaptureMetadata.transferKey: bytes]
        )
    }

    func remove(for audioURL: URL) throws {
        let url = metadataURL(for: audioURL)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func metadataURL(for audioURL: URL) -> URL {
        audioURL.deletingLastPathComponent().appendingPathComponent(
            "\(audioURL.lastPathComponent).watch-relay.json"
        )
    }
}
