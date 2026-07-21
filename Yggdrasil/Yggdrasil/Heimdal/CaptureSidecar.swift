import Foundation

extension CaptureRecorder {
    struct ActiveCapture {
        let generation: UInt64
        let url: URL
        let recordedStartAt: Date
        var interruptions: Int
    }

    enum FinalizationMode {
        case delegateCompletion
        case forcedCompletion
    }
}

enum CaptureSourceSurface: String, Codable, Equatable {
    case iphoneApp = "iphone-app"
    case watchRelay = "watch-relay"
}

struct CaptureLocation: Codable, Equatable {
    let lat: Double
    let lon: Double
    let precisionM: Double

    enum CodingKeys: String, CodingKey {
        case lat
        case lon
        case precisionM = "precision_m"
    }
}

/// Operator-controlled capture context. Location remains nil unless a future
/// explicit opt-in surface supplies a value; recording requires microphone
/// permission only by default.
struct CaptureSidecarSettings: Equatable {
    var enabledLocation: CaptureLocation?

    static let microphoneOnly = CaptureSidecarSettings(enabledLocation: nil)
}

struct CaptureTimeMetadataSidecar: Codable, Equatable {
    static let version = 1

    let sidecarVersion: Int
    let deviceID: String
    let recordedStartAt: Date
    let recordedEndAt: Date
    let timezone: String
    let interruptions: Int
    let sourceSurface: CaptureSourceSurface
    let location: CaptureLocation?

    enum CodingKeys: String, CodingKey {
        case sidecarVersion = "sidecar_version"
        case deviceID = "device_id"
        case recordedStartAt = "recorded_start_at"
        case recordedEndAt = "recorded_end_at"
        case timezone
        case interruptions
        case sourceSurface = "source_surface"
        case location
    }

    init(item: CaptureSessionModel.StagedItem, settings: CaptureSidecarSettings) {
        sidecarVersion = Self.version
        deviceID = item.deviceID
        recordedStartAt = item.recordedStartAt
        recordedEndAt = item.recordedEndAt
        timezone = TimeZone.current.identifier
        interruptions = item.interruptions
        sourceSurface = item.sourceSurface
        location = settings.enabledLocation
    }
}

protocol CaptureSidecarWriting {
    /// Called only after the audio's final name has been atomically published.
    func write(sidecar: CaptureTimeMetadataSidecar, alongside audioURL: URL) throws
}

struct CaptureSidecarWriter: CaptureSidecarWriting {
    private let coordinator: CaptureDeliveryCoordinating
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    init(
        coordinator: CaptureDeliveryCoordinating = NSFileCoordinatorCaptureDeliveryAccess(),
        fileManager: FileManager = .default
    ) {
        self.coordinator = coordinator
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func write(sidecar: CaptureTimeMetadataSidecar, alongside audioURL: URL) throws {
        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw CaptureDeliveryError.missingSource
        }
        let bytes = try encoder.encode(sidecar)
        let folderURL = audioURL.deletingLastPathComponent()
        let finalURL = folderURL.appendingPathComponent("\(audioURL.lastPathComponent).capture.json")
        let tempURL = folderURL.appendingPathComponent("\(audioURL.lastPathComponent).capture.json.uploading")

        try coordinator.coordinateWrite(in: folderURL) { coordinatedFolderURL in
            let coordinatedFinalURL = coordinatedFolderURL.appendingPathComponent(finalURL.lastPathComponent)
            let coordinatedTempURL = coordinatedFolderURL.appendingPathComponent(tempURL.lastPathComponent)
            if fileManager.fileExists(atPath: coordinatedFinalURL.path) {
                guard try Data(contentsOf: coordinatedFinalURL) == bytes else {
                    throw CaptureDeliveryError.sidecarNameCollision
                }
                return
            }
            if fileManager.fileExists(atPath: coordinatedTempURL.path) {
                try fileManager.removeItem(at: coordinatedTempURL)
            }
            try bytes.write(to: coordinatedTempURL, options: .atomic)
            guard try Data(contentsOf: coordinatedTempURL) == bytes else {
                throw CaptureDeliveryError.incompleteSidecarPlacement
            }
            try fileManager.moveItem(at: coordinatedTempURL, to: coordinatedFinalURL)
            guard try Data(contentsOf: coordinatedFinalURL) == bytes else {
                try? fileManager.removeItem(at: coordinatedFinalURL)
                throw CaptureDeliveryError.incompleteSidecarPlacement
            }
        }
    }
}
