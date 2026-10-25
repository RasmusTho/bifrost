import XCTest
import AVFoundation
import YggdrasilCore
@testable import Yggdrasil

final class TestSeamGatingTests: XCTestCase {
    func testFixtureVaultSeamRequiresLaunchArgument() {
        let withoutTestMode = UITestLaunchConfiguration(arguments: ["-ui-testing-uat-fixture"])
        XCTAssertNil(withoutTestMode.fixtureKind)
        XCTAssertFalse(withoutTestMode.holdsAuthenticationGate)

        let fixtureMode = UITestLaunchConfiguration(
            arguments: ["-ui-testing", "-ui-testing-uat-fixture", "fixture-7"]
        )
        XCTAssertEqual(fixtureMode.fixtureKind, .uat)
        XCTAssertEqual(fixtureMode.fixtureIdentifier, "fixture-7")

        let lockedMode = UITestLaunchConfiguration(arguments: ["-ui-testing", "-ui-testing-auth-locked"])
        XCTAssertTrue(lockedMode.holdsAuthenticationGate)
    }

    func testCompanionTTSBaseURLRejectsUntrustedURLsAndDefaultsToUnconfigured() {
        XCTAssertThrowsError(try CompanionTTSClient.validate(baseURL: ""))
        XCTAssertThrowsError(try CompanionTTSClient.validate(baseURL: "https://example.com"))
        XCTAssertThrowsError(try CompanionTTSClient.validate(baseURL: "http://device.tailnet.ts.net"))
        XCTAssertThrowsError(try CompanionTTSClient.validate(baseURL: "http://192.168.1.20/path"))
        XCTAssertNoThrow(try CompanionTTSClient.validate(baseURL: "http://192.168.1.20:8765"))
        XCTAssertNoThrow(try CompanionTTSClient.validate(baseURL: "https://device.tailnet.ts.net"))
        XCTAssertTrue(HeimdalMediaAPITransport.isPrivateHost("192.168.1.20"))
        XCTAssertTrue(HeimdalMediaAPITransport.isPrivateHost("device.tailnet.ts.net", scheme: "https"))
        XCTAssertFalse(HeimdalMediaAPITransport.isPrivateHost("device.tailnet.ts.net"))
        XCTAssertFalse(HeimdalMediaAPITransport.isPrivateHost("example.com"))
    }

    func testCompanionTTSClientUsesGovernedContractAndFailsClosed() async throws {
        let key = String(repeating: "a", count: 64)
        let planJSON = """
        {
          "enabled": true,
          "local_only": true,
          "allow_browser_fallback": false,
          "allow_cloud_fallback": false,
          "normalized_text": "A selected note",
          "language": "en",
          "provider": "piper",
          "voice_id": "en_US-amy-medium",
          "provider_available": true,
          "provider_reason": null,
          "warnings": [],
          "cache_key": "\(key)",
          "cached": false,
          "mixed_language": false,
          "segments": [{
            "index": 0,
            "text": "A selected note",
            "language": "en",
            "provider": "piper",
            "voice_id": "en_US-amy-medium"
          }],
          "audio_url": "/api/companion/tts/audio/\(key).wav"
        }
        """
        let plan = try JSONDecoder().decode(CompanionTTSPlan.self, from: Data(planJSON.utf8))
        XCTAssertTrue(plan.localOnly)
        XCTAssertFalse(plan.allowBrowserFallback)
        XCTAssertFalse(plan.allowCloudFallback)
        XCTAssertTrue(plan.canRequestAudio)
        XCTAssertEqual(plan.normalizedText, "A selected note")

        let unsafePlanJSON = planJSON.replacingOccurrences(
            of: "\"allow_cloud_fallback\": false",
            with: "\"allow_cloud_fallback\": true"
        )
        let unsafePlan = try JSONDecoder().decode(CompanionTTSPlan.self, from: Data(unsafePlanJSON.utf8))
        XCTAssertFalse(unsafePlan.canRequestAudio, "A plan that permits cloud fallback must never be playable.")
        XCTAssertFalse(
            UITestLaunchConfiguration(arguments: ["-ui-testing-read-aloud"]).usesReadAloudTestSeam
        )
        XCTAssertTrue(
            UITestLaunchConfiguration(arguments: ["-ui-testing", "-ui-testing-read-aloud"]).usesReadAloudTestSeam
        )
    }

    func testReadAloudUsesServerAudioOnlyAndStopsOnFailureOrInterruption() async throws {
        let center = NotificationCenter()
        let player = await MainActor.run { RecordingServerAudioPlayer() }
        let successfulClient = ScriptedReadAloudClient(shouldFailSynthesis: false)
        let model = await MainActor.run {
            MimerReadAloudModel(
                client: successfulClient,
                player: player,
                notificationCenter: center,
                usesTestSeam: false
            )
        }

        await model.review(text: "A selected note", baseURL: "")
        let reviewedPlan = await MainActor.run { model.plan }
        XCTAssertNotNil(reviewedPlan)
        let playCountBeforeExplicitAction = await MainActor.run { successfulClient.synthesisCount }
        XCTAssertEqual(playCountBeforeExplicitAction, 0, "Reviewing a plan must not request audio.")

        await model.play()
        let isPlaying = await MainActor.run { model.isPlaying }
        XCTAssertTrue(isPlaying)
        let receivedData = await MainActor.run { player.receivedData }
        XCTAssertEqual(receivedData, Data("server-generated-wav".utf8))
        let synthesisCount = await MainActor.run { successfulClient.synthesisCount }
        XCTAssertEqual(synthesisCount, 1)

        let stopCountBeforeInterruption = await MainActor.run { player.stopCount }
        await MainActor.run { model.handleAudioSessionChange() }
        let stoppedAfterInterruption = await MainActor.run {
            !model.isPlaying && player.stopCount > stopCountBeforeInterruption
        }
        XCTAssertTrue(stoppedAfterInterruption)

        let failingPlayer = await MainActor.run { RecordingServerAudioPlayer() }
        let failingClient = ScriptedReadAloudClient(shouldFailSynthesis: true)
        let failingModel = await MainActor.run {
            MimerReadAloudModel(
                client: failingClient,
                player: failingPlayer,
                notificationCenter: NotificationCenter(),
                usesTestSeam: false
            )
        }
        await failingModel.review(text: "A selected note", baseURL: "")
        await failingModel.play()
        let failedClosed = await MainActor.run { !failingModel.isPlaying && failingPlayer.playCount == 0 }
        XCTAssertTrue(failedClosed)
    }

    func testStopInvalidatesPendingSynthesisAndStaleCompletionCannotClearNewRequest() async throws {
        let client = DelayedReadAloudClient()
        let player = await MainActor.run { RecordingServerAudioPlayer() }
        let model = await MainActor.run {
            MimerReadAloudModel(
                client: client,
                player: player,
                notificationCenter: NotificationCenter(),
                usesTestSeam: false
            )
        }
        await model.review(text: "A selected note", baseURL: "")

        let firstPlay = Task { await model.play() }
        await client.gate.waitForCalls(1)
        await MainActor.run { model.stop() }
        let stoppedPendingRequest = await MainActor.run { !model.isSynthesizing && !model.isPlaying }
        XCTAssertTrue(stoppedPendingRequest)

        let secondPlay = Task { await model.play() }
        await client.gate.waitForCalls(2)
        await client.gate.complete(call: 1, with: try Self.serverAudio(cacheKey: client.cacheKey))
        await firstPlay.value

        let newerRequestStillActive = await MainActor.run { model.isSynthesizing && !model.isPlaying }
        XCTAssertTrue(newerRequestStillActive, "A stale completion must not clear the newer synthesis state.")
        let noStalePlayback = await MainActor.run { player.playCount == 0 }
        XCTAssertTrue(noStalePlayback, "Stop must prevent a late synthesis response from starting playback.")

        let duplicatePlay = Task { await model.play() }
        await duplicatePlay.value
        let synthesisCallsAfterDuplicate = await client.gate.callCount()
        XCTAssertEqual(synthesisCallsAfterDuplicate, 2, "Only one synthesis request may be active at a time.")

        await client.gate.complete(call: 2, with: try Self.serverAudio(cacheKey: client.cacheKey))
        await secondPlay.value
        let finalState = await MainActor.run { (model.isPlaying, player.playCount) }
        XCTAssertTrue(finalState.0)
        XCTAssertEqual(finalState.1, 1)
    }

    func testStopDuringPlanningAllowsNewReviewAndIgnoresStalePlan() async throws {
        let client = DelayedPlanReadAloudClient()
        let model = await MainActor.run {
            MimerReadAloudModel(
                client: client,
                player: RecordingServerAudioPlayer(),
                notificationCenter: NotificationCenter(),
                usesTestSeam: false
            )
        }

        let firstReview = Task { await model.review(text: "Old note", baseURL: "") }
        await client.gate.waitForCalls(1)
        await MainActor.run { model.stop() }
        let planningStopped = await MainActor.run { !model.isPlanning }
        XCTAssertTrue(planningStopped)

        let secondReview = Task { await model.review(text: "New note", baseURL: "") }
        await client.gate.waitForCalls(2)
        let plan = try await ScriptedReadAloudClient(shouldFailSynthesis: false).plan(text: "New note")
        await client.gate.complete(call: 1, with: plan)
        await firstReview.value
        let newerReviewUnaffected = await MainActor.run { model.isPlanning && model.plan == nil }
        XCTAssertTrue(newerReviewUnaffected, "A stale plan must not finish or populate the newer review.")

        await client.gate.complete(call: 2, with: plan)
        await secondReview.value
        let finalState = await MainActor.run { (!model.isPlanning, model.plan?.normalizedText) }
        XCTAssertTrue(finalState.0)
        XCTAssertEqual(finalState.1, "A selected note")
    }

    private static func serverAudio(cacheKey: String) throws -> CompanionTTSAudio {
        let json = """
        {
          "ok": true,
          "state": "generated",
          "cached": false,
          "cache_key": "\(cacheKey)",
          "audio_url": "/api/companion/tts/audio/\(cacheKey).wav",
          "content_type": "audio/wav",
          "provider": "piper",
          "language": "en",
          "voice_id": "fixture",
          "reason": null
        }
        """
        let receipt = try JSONDecoder().decode(CompanionTTSSynthesis.self, from: Data(json.utf8))
        return CompanionTTSAudio(receipt: receipt, data: Data("server-generated-wav".utf8))
    }
}

private final class DelayedReadAloudClient: CompanionTTSServing, @unchecked Sendable {
    let cacheKey = String(repeating: "c", count: 64)
    let gate = ReadAloudSynthesisGate()

    func plan(text: String) async throws -> CompanionTTSPlan {
        let json = """
        {
          "enabled": true,
          "local_only": true,
          "allow_browser_fallback": false,
          "allow_cloud_fallback": false,
          "normalized_text": "A selected note",
          "language": "en",
          "provider": "piper",
          "voice_id": "fixture",
          "provider_available": true,
          "provider_reason": null,
          "warnings": [],
          "cache_key": "\(cacheKey)",
          "cached": false,
          "mixed_language": false,
          "segments": [],
          "audio_url": "/api/companion/tts/audio/\(cacheKey).wav"
        }
        """
        return try JSONDecoder().decode(CompanionTTSPlan.self, from: Data(json.utf8))
    }

    func synthesize(text: String, expecting cacheKey: String) async throws -> CompanionTTSAudio {
        try await gate.waitForNextAudio()
    }
}

private final class DelayedPlanReadAloudClient: CompanionTTSServing, @unchecked Sendable {
    let gate = ReadAloudPlanGate()

    func plan(text: String) async throws -> CompanionTTSPlan {
        try await gate.waitForNextPlan()
    }

    func synthesize(text: String, expecting cacheKey: String) async throws -> CompanionTTSAudio {
        throw CompanionTTSClientError.unavailable("not used in planning test")
    }
}

private actor ReadAloudPlanGate {
    private var pending: [Int: CheckedContinuation<CompanionTTSPlan, Error>] = [:]
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var calls = 0

    func waitForNextPlan() async throws -> CompanionTTSPlan {
        calls += 1
        let currentCall = calls
        let ready = callWaiters.filter { currentCall >= $0.0 }
        callWaiters.removeAll { currentCall >= $0.0 }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { pending[currentCall] = $0 }
    }

    func waitForCalls(_ expectedCount: Int) async {
        guard calls < expectedCount else { return }
        await withCheckedContinuation { callWaiters.append((expectedCount, $0)) }
    }

    func complete(call: Int, with plan: CompanionTTSPlan) {
        pending.removeValue(forKey: call)?.resume(returning: plan)
    }
}

private actor ReadAloudSynthesisGate {
    private var pending: [Int: CheckedContinuation<CompanionTTSAudio, Error>] = [:]
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var calls = 0

    func waitForNextAudio() async throws -> CompanionTTSAudio {
        calls += 1
        let currentCall = calls
        let ready = callWaiters.filter { currentCall >= $0.0 }
        callWaiters.removeAll { currentCall >= $0.0 }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { pending[currentCall] = $0 }
    }

    func waitForCalls(_ expectedCount: Int) async {
        guard calls < expectedCount else { return }
        await withCheckedContinuation { callWaiters.append((expectedCount, $0)) }
    }

    func callCount() -> Int { calls }

    func complete(call: Int, with audio: CompanionTTSAudio) {
        pending.removeValue(forKey: call)?.resume(returning: audio)
    }
}

private final class ScriptedReadAloudClient: CompanionTTSServing, @unchecked Sendable {
    let shouldFailSynthesis: Bool
    private(set) var synthesisCount = 0

    init(shouldFailSynthesis: Bool) {
        self.shouldFailSynthesis = shouldFailSynthesis
    }

    func plan(text: String) async throws -> CompanionTTSPlan {
        let key = String(repeating: "a", count: 64)
        let json = """
        {
          "enabled": true,
          "local_only": true,
          "allow_browser_fallback": false,
          "allow_cloud_fallback": false,
          "normalized_text": "A selected note",
          "language": "en",
          "provider": "piper",
          "voice_id": "fixture",
          "provider_available": true,
          "provider_reason": null,
          "warnings": [],
          "cache_key": "\(key)",
          "cached": false,
          "mixed_language": false,
          "segments": [],
          "audio_url": "/api/companion/tts/audio/\(key).wav"
        }
        """
        return try JSONDecoder().decode(CompanionTTSPlan.self, from: Data(json.utf8))
    }

    func synthesize(text: String, expecting cacheKey: String) async throws -> CompanionTTSAudio {
        synthesisCount += 1
        if shouldFailSynthesis { throw CompanionTTSClientError.unavailable("provider unavailable") }
        let json = """
        {
          "ok": true,
          "state": "generated",
          "cached": false,
          "cache_key": "\(cacheKey)",
          "audio_url": "/api/companion/tts/audio/\(cacheKey).wav",
          "content_type": "audio/wav",
          "provider": "piper",
          "language": "en",
          "voice_id": "fixture",
          "reason": null
        }
        """
        let receipt = try JSONDecoder().decode(CompanionTTSSynthesis.self, from: Data(json.utf8))
        return CompanionTTSAudio(receipt: receipt, data: Data("server-generated-wav".utf8))
    }
}

@MainActor
private final class RecordingServerAudioPlayer: MimerServerAudioPlaying {
    private(set) var receivedData: Data?
    private(set) var playCount = 0
    private(set) var stopCount = 0

    func play(_ data: Data, onFinish: @escaping () -> Void) throws {
        receivedData = data
        playCount += 1
    }

    func stop() { stopCount += 1 }
}
