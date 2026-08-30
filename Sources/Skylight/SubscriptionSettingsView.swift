import SwiftUI
import SkylightCore

/// Settings → Subscriptions: every agent CLI on this machine, whether it is
/// connected, and one click to connect it.
///
/// The honest posture is the whole feature. This pane never shows a token,
/// never asks for one, and cannot: the only things it knows are what each CLI
/// printed about itself and whether a credential file exists on disk.
struct SubscriptionSettingsView: View {
    @EnvironmentObject private var state: AppState

    /// Only harnesses actually installed. The New sheet is where you go to
    /// install something; a Settings pane listing eleven CLIs you do not have
    /// is a catalogue, not a status board.
    private var installed: [Harness] {
        Catalog.harnesses.filter {
            state.sessions.cachedResolveHarness($0.id) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if installed.isEmpty {
                Text("No agent CLIs found. Install one from ⌘T and it will appear here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(installed) { harness in
                            row(harness)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(18)
        // One of the three declared triggers. Not a timer.
        .task { state.refreshSubscriptions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your subscriptions")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Text("Skylight runs each CLI's own login in a terminal. It never sees or stores your credentials.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ harness: Harness) -> some View {
        let subscription = state.subscriptionState(harness.id)
        let rowState = HarnessRowState.of(installed: true, subscription: subscription)
        return HStack(spacing: 10) {
            harnessIcon(harness)
            VStack(alignment: .leading, spacing: 1) {
                Text(harness.displayName)
                    .font(.system(size: 13, weight: .medium))
                if let detail = SubscriptionCopy.rowDetail(for: harness,
                                                           state: subscription) {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if harness.authProbe?.statusCommand == nil {
                    // Say why it is blank rather than leaving a gap that reads
                    // as a bug. This is the same "we will not guess" rule the
                    // autonomy toggles follow.
                    Text("No verified way to check — the CLI will tell you when it runs")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if state.probing.contains(harness.id) {
                ProgressView().controlSize(.small)
            } else if rowState == .signedOut,
                      SubscriptionCopy.signInSpec(for: harness) != nil {
                Button("Sign in") { signIn(harness) }
                    .buttonStyle(.pressable(scale: 0.94))
                    .font(.system(size: 11, weight: .semibold))
            } else if case .signedIn = subscription {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                    .help(lastCheckedText(harness) ?? "Signed in")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            Button("Check again") { state.refreshSubscriptions(force: true) }
                .buttonStyle(.pressable(scale: 0.97))
                .font(.system(size: 12))
                .disabled(!state.probing.isEmpty)
            Spacer()
        }
    }

    private func lastCheckedText(_ harness: Harness) -> String? {
        guard let checked = state.subscriptions.lastChecked(harness.id) else {
            return nil
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked \(formatter.localizedString(for: checked, relativeTo: Date()))"
    }

    private func signIn(_ harness: Harness) {
        guard let spec = SubscriptionCopy.signInSpec(for: harness) else { return }
        state.launchSignIn(spec, harness: harness)
        // The terminal is the point — get out of Settings so it is visible.
        NSApp.keyWindow?.close()
    }

    @ViewBuilder
    private func harnessIcon(_ harness: Harness) -> some View {
        if let brand = harness.brand {
            BrandIcon(brand: brand, size: 18, filled: false)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }
}
