import AVFoundation
import SwiftUI
import YggdrasilCore

enum MimerCompanionSettings {
    static let baseURLKey = "mimer.companion.baseURL"
}

@MainActor
protocol MimerServerAudioPlaying: AnyObject {
    func play(_ data: Data, onFinish: @escaping () -> Void) throws
    func stop()
}

@MainActor
final class MimerReadAloudModel: ObservableObject {
    @Published private(set) var plan: CompanionTTSPlan?
    @Published private(set) var isPlanning = false
    @Published private(set) var isSynthesizing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var message: String?
    @Published private(set) var synthesisRequestCount = 0

    let usesTestSeam: Bool
    private let clientOverride: CompanionTTSServing?
    private var activeClient: CompanionTTSServing?
    private let player: MimerServerAudioPlaying
    private let notificationCenter: NotificationCenter
    private var interruptionObservers: [NSObjectProtocol] = []
    private var requestedText: String?
    private var requestID = UUID()

    init(
        client: CompanionTTSServing? = nil,
        player: MimerServerAudioPlaying? = nil,
        notificationCenter: NotificationCenter = .default,
        usesTestSeam: Bool = UITestLaunchConfiguration.current.usesReadAloudTestSeam
    ) {
        self.clientOverride = client
        self.notificationCenter = notificationCenter
        self.usesTestSeam = usesTestSeam
        self.player = player ?? Self.makeDefaultPlayer(usesTestSeam: usesTestSeam)
        observeAudioSessionChanges()
    }

    deinit {
        interruptionObservers.forEach(notificationCenter.removeObserver)
    }

    func review(text: String, baseURL: String) async {
        guard !isPlanning, !isSynthesizing, !isPlaying else { return }
        reset()
        let currentRequest = requestID
        requestedText = text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "This note has no readable text."
            return
        }

        let client: CompanionTTSServing
        do {
            client = try makeClient(baseURL: baseURL)
        } catch {
            message = error.localizedDescription
            return
        }
        activeClient = client

        isPlanning = true
        defer {
            if currentRequest == requestID { isPlanning = false }
        }
        do {
            let reviewedPlan = try await client.plan(text: text)
            guard currentRequest == requestID else { return }
            plan = reviewedPlan
            if !reviewedPlan.canRequestAudio {
                message = reviewedPlan.providerReason.map { "Audio is unavailable: \($0)." }
                    ?? "No cached audio or available local provider is ready."
            }
        } catch {
            guard currentRequest == requestID else { return }
            message = error.localizedDescription
        }
    }

    func play() async {
        guard !isPlanning, !isSynthesizing, !isPlaying,
              let plan, plan.canRequestAudio, let requestedText else { return }
        let currentRequest = requestID
        isSynthesizing = true
        message = nil
        defer {
            if currentRequest == requestID { isSynthesizing = false }
        }
        do {
            guard let client = activeClient else { return }
            synthesisRequestCount += 1
            let audio = try await client.synthesize(text: requestedText, expecting: plan.cacheKey)
            guard currentRequest == requestID else { return }
            try player.play(audio.data) { [weak self] in
                guard let self else { return }
                guard self.requestID == currentRequest else { return }
                self.isPlaying = false
                if self.message == nil { self.message = "Playback finished." }
            }
            isPlaying = true
            message = "Playing server audio."
        } catch {
            guard currentRequest == requestID else { return }
            player.stop()
            isPlaying = false
            message = error.localizedDescription
        }
    }

    func stop() {
        requestID = UUID()
        player.stop()
        isPlanning = false
        isPlaying = false
        isSynthesizing = false
        message = "Playback stopped."
    }

    func reset() {
        requestID = UUID()
        player.stop()
        requestedText = nil
        activeClient = nil
        plan = nil
        isPlanning = false
        isSynthesizing = false
        isPlaying = false
        message = nil
    }

    func handleAudioSessionChange() {
        guard isPlaying || isSynthesizing else { return }
        requestID = UUID()
        player.stop()
        isPlaying = false
        isSynthesizing = false
        message = "Playback stopped because the audio session changed. Tap Play to try again."
    }

    private func makeClient(baseURL: String) throws -> CompanionTTSServing {
        if let clientOverride { return clientOverride }
        #if DEBUG
        if usesTestSeam { return UITestCompanionTTSClient() }
        #endif
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompanionTTSClientError.invalidBaseURL
        }
        return try CompanionTTSClient(baseURL: baseURL)
    }

    private static func makeDefaultPlayer(usesTestSeam: Bool) -> MimerServerAudioPlaying {
        #if DEBUG
        if usesTestSeam { return UITestSilentServerAudioPlayer() }
        #endif
        return CompanionServerAudioPlayer()
    }

    private func observeAudioSessionChanges() {
        let session = AVAudioSession.sharedInstance()
        let names: [Notification.Name] = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification
        ]
        interruptionObservers = names.map { name in
            notificationCenter.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleAudioSessionChange()
                }
            }
        }
    }
}

struct MimerReadAloudControls: View {
    let text: String

    @AppStorage(MimerCompanionSettings.baseURLKey) private var companionBaseURL = ""
    @State private var isReviewPresented = false
    @StateObject private var model = MimerReadAloudModel()

    var body: some View {
        Button("Read Aloud") {
            isReviewPresented = true
            Task { await model.review(text: text, baseURL: companionBaseURL) }
        }
        .accessibilityIdentifier("mimer.readAloud.review")
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .sheet(
            isPresented: $isReviewPresented,
            onDismiss: { model.reset() },
            content: { reviewSheet }
        )
        .onChange(of: text) { _, _ in model.reset() }
        .onChange(of: companionBaseURL) { _, _ in model.reset() }
        .onDisappear { model.stop() }
    }

    private var reviewSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: YggTheme.Spacing.md) {
                    if model.isPlanning {
                        ProgressView("Reviewing the server speech plan…")
                            .accessibilityIdentifier("mimer.readAloud.planning")
                    }
                    if let plan = model.plan {
                        Text("Server speech plan")
                            .font(YggTheme.Typography.title)
                            .accessibilityIdentifier("mimer.readAloud.plan.title")
                        Text(plan.normalizedText)
                            .font(YggTheme.Typography.body)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("mimer.readAloud.plan.text")
                        VStack(alignment: .leading, spacing: YggTheme.Spacing.xs) {
                            LabeledContent("Language", value: plan.language)
                            LabeledContent("Provider", value: plan.provider)
                            LabeledContent("Voice", value: plan.voiceID)
                            LabeledContent("Server cache", value: plan.cached ? "Available" : "Not cached")
                        }
                        if !plan.segments.isEmpty {
                            VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
                                Text(plan.mixedLanguage ? "Speech segments" : "Speech segment")
                                    .font(YggTheme.Typography.sectionHeader)
                                ForEach(plan.segments, id: \.index) { segment in
                                    VStack(alignment: .leading, spacing: YggTheme.Spacing.xs) {
                                        Text("Segment \(segment.index + 1)")
                                            .font(YggTheme.Typography.caption)
                                        Text(segment.text)
                                            .font(YggTheme.Typography.body)
                                            .accessibilityIdentifier("mimer.readAloud.segment.\(segment.index).text")
                                        Text("Language: \(segment.language)")
                                            .accessibilityIdentifier(
                                                "mimer.readAloud.segment.\(segment.index).language"
                                            )
                                        Text("Provider: \(segment.provider ?? "Not specified")")
                                            .accessibilityIdentifier(
                                                "mimer.readAloud.segment.\(segment.index).provider"
                                            )
                                        Text("Voice: \(segment.voiceID ?? "Not specified")")
                                            .accessibilityIdentifier("mimer.readAloud.segment.\(segment.index).voice")
                                    }
                                    .padding(.vertical, YggTheme.Spacing.xs)
                                }
                            }
                        }
                        if !plan.warnings.isEmpty {
                            Text(plan.warnings.joined(separator: ", "))
                                .font(YggTheme.Typography.caption)
                        }
                        if let providerReason = plan.providerReason, !plan.cached {
                            Text("Local provider unavailable: \(providerReason)")
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await model.play() }
                        } label: {
                            if model.isSynthesizing {
                                Label("Requesting server audio…", systemImage: "waveform")
                            } else {
                                Label("Play", systemImage: "play.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mimer.readAloud.play")
                        .disabled(!plan.canRequestAudio || model.isSynthesizing)
                        if model.isPlaying {
                            Button("Stop") { model.stop() }
                                .accessibilityIdentifier("mimer.readAloud.stop")
                        }
                    }
                    if let message = model.message {
                        Text(message)
                            .font(YggTheme.Typography.caption)
                            .accessibilityIdentifier("mimer.readAloud.status")
                    }
                    if model.plan == nil && !model.isPlanning && model.message == nil {
                        Text("Review the server plan before any audio is requested.")
                            .font(YggTheme.Typography.body)
                    }
                    if model.usesTestSeam {
                        Text("Automation uses a scripted plan and silent playback seam.")
                            .font(YggTheme.Typography.caption)
                            .accessibilityIdentifier("mimer.readAloud.testSeam")
                        Text("Synthesis requests: \(model.synthesisRequestCount)")
                            .accessibilityIdentifier("mimer.readAloud.testSynthesisCount")
                    }
                }
                .padding(YggTheme.Spacing.md)
            }
            .navigationTitle("Read Aloud")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isReviewPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

@MainActor
private final class CompanionServerAudioPlayer: NSObject,
    MimerServerAudioPlaying,
    @preconcurrency AVAudioPlayerDelegate {
    private var audioPlayer: AVAudioPlayer?
    private var onFinish: (() -> Void)?

    func play(_ data: Data, onFinish: @escaping () -> Void) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        guard player.prepareToPlay(), player.play() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CompanionAudioPlaybackError.couldNotStart
        }
        audioPlayer = player
        self.onFinish = onFinish
    }

    func stop() {
        let wasPlaying = audioPlayer != nil
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if wasPlaying {
            let finish = onFinish
            onFinish = nil
            finish?()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let activePlayer = audioPlayer, activePlayer === player else { return }
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let finish = onFinish
        onFinish = nil
        finish?()
    }
}

private enum CompanionAudioPlaybackError: LocalizedError {
    case couldNotStart

    var errorDescription: String? { "The server WAV could not be played." }
}

#if DEBUG
private struct UITestCompanionTTSClient: CompanionTTSServing {
    func plan(text: String) async throws -> CompanionTTSPlan {
        let object: [String: Any] = [
            "enabled": true,
            "local_only": true,
            "allow_browser_fallback": false,
            "allow_cloud_fallback": false,
            "normalized_text": "Fixture note.",
            "language": "en",
            "provider": "scripted-test-provider",
            "voice_id": "scripted-test-voice",
            "provider_available": true,
            "provider_reason": NSNull(),
            "warnings": [],
            "cache_key": String(repeating: "a", count: 64),
            "cached": false,
            "mixed_language": true,
            "segments": [
                ["index": 0, "text": "Fixture note.", "language": "en", "provider": "scripted-en",
                 "voice_id": "en-test"],
                ["index": 1, "text": "Anteckning.", "language": "sv", "provider": "scripted-sv",
                 "voice_id": "sv-test"]
            ],
            "audio_url": "/api/companion/tts/audio/\(String(repeating: "a", count: 64)).wav"
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(CompanionTTSPlan.self, from: data)
    }

    func synthesize(text: String, expecting cacheKey: String) async throws -> CompanionTTSAudio {
        let receiptObject: [String: Any] = [
            "ok": true,
            "state": "generated",
            "cached": false,
            "cache_key": cacheKey,
            "audio_url": "/api/companion/tts/audio/\(cacheKey).wav",
            "content_type": "audio/wav",
            "provider": "scripted-test-provider",
            "language": "en",
            "voice_id": "scripted-test-voice",
            "reason": NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: receiptObject)
        let receipt = try JSONDecoder().decode(CompanionTTSSynthesis.self, from: data)
        return CompanionTTSAudio(receipt: receipt, data: Data("silent-test-seam".utf8))
    }
}

@MainActor
private final class UITestSilentServerAudioPlayer: MimerServerAudioPlaying {
    func play(_ data: Data, onFinish: @escaping () -> Void) throws {}
    func stop() {}
}
#endif
