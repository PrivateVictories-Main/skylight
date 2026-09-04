import SwiftUI

enum SessionKeeperIssue: Equatable, Sendable {
    case incompatible(found: Int, expected: Int)
    case busy
    case unresponsive

    var title: String {
        switch self {
        case .incompatible: "Your sessions need a compatible Skylight build"
        case .busy: "This workspace is open in another Skylight app"
        case .unresponsive: "The session keeper could not be reached"
        }
    }

    var message: String {
        switch self {
        case .incompatible:
            "Existing sessions were left untouched. Use a compatible Skylight build to reconnect, or finish those sessions in the previous build before retrying."
        case .busy:
            "Close the other Skylight app, then retry to reconnect to its sessions."
        case .unresponsive:
            "No sessions were replaced. Give the keeper a moment, then retry."
        }
    }
}

/// Appears only when opening needs attention; normal terminals keep their
/// existing bare surface. Recovery never offers an implicit destructive reset.
struct SessionPreparationView: View {
    let issue: SessionKeeperIssue?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let issue {
                Text(issue.title).font(.system(size: 13, weight: .medium))
                Text(issue.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry Connection", action: retry)
                    .padding(.top, 4)
            } else {
                ProgressView().controlSize(.small)
                Text("Opening session…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
