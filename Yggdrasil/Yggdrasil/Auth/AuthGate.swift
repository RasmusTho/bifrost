import LocalAuthentication
import SwiftUI

/// Yggdrasil's auth: a local device gate (Face ID / Touch ID / passcode) in
/// front of the vault contents. There is no account/server-side identity —
/// this is a single-user, local-first shell over the same vault Obsidian
/// already opens, so auth means "prove you're the device owner," not "log
/// into a service."
@MainActor
final class AuthGate: ObservableObject {
    enum State: Equatable {
        case locked
        case authenticating
        case unlocked
        case unavailable(reason: String)
    }

    @Published private(set) var state: State

    init(initialState: State = .locked) {
        state = initialState
    }

    func authenticate() {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            // No passcode/biometry enrolled — fail open rather than lock the
            // owner out of their own single-user vault shell.
            state = .unlocked
            return
        }
        state = .authenticating
        let reason = "Unlock Yggdrasil to open your vault."
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if success {
                    self.state = .unlocked
                } else {
                    self.state = .unavailable(reason: error?.localizedDescription ?? "Authentication failed.")
                }
            }
        }
    }

    func retry() {
        state = .locked
        authenticate()
    }
}

struct AuthGateView: View {
    @ObservedObject var gate: AuthGate

    var body: some View {
        VStack(spacing: YggTheme.Spacing.lg) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(YggTheme.Color.accent)
            Text("Yggdrasil")
                .font(YggTheme.Typography.title)
            switch gate.state {
            case .locked, .authenticating:
                ProgressView()
            case .unavailable(let reason):
                Text(reason)
                    .font(YggTheme.Typography.caption)
                    .foregroundStyle(YggTheme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, YggTheme.Spacing.xl)
                YggPrimaryButton(title: "Try Again") { gate.retry() }
                    .padding(.horizontal, YggTheme.Spacing.xl)
            case .unlocked:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YggTheme.Color.background)
        .onAppear {
            if gate.state == .locked {
                gate.authenticate()
            }
        }
    }
}
