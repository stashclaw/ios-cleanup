import SwiftUI

// Floating toast that appears after a deletion is scheduled.
// PhotoKit deletions are not reversible through the public API, so tapping Undo here
// simply cancels the deferred commit window before the change is finalized.
// Renders through the shared DuckToast shell.
struct UndoToast: View {
    let toastID: UUID
    let deadline: Date
    let freedBytes: Int64
    let freedCount: Int
    let onUndo: () -> Void

    private let undoWindowSeconds: TimeInterval = 10

    private var freedLabel: String {
        ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)
    }

    private var freedCountLabel: String {
        "\(freedCount) photo\(freedCount == 1 ? "" : "s")"
    }

    private func remainingSeconds(at date: Date) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(date))))
    }

    private func progress(at date: Date) -> Double {
        min(max(deadline.timeIntervalSince(date) / undoWindowSeconds, 0), 1)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            DuckToast(
                style: .destructive,
                message: "Removing \(freedCountLabel)",
                detail: freedLabel,
                trailingDetail: "\(remainingSeconds(at: context.date))s",
                actionLabel: "Undo",
                onAction: onUndo,
                progress: progress(at: context.date)
            )
        }
        .id(toastID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pending deletion of \(freedCountLabel), \(freedLabel), \(remainingSeconds(at: Date())) seconds to undo")
    }
}

private struct DeletionUndoToastModifier: ViewModifier {
    @EnvironmentObject private var deletionManager: DeletionManager

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 8) {
            if deletionManager.toastVisible {
                UndoToast(
                    toastID: deletionManager.toastID,
                    deadline: deletionManager.toastDeadline,
                    freedBytes: deletionManager.toastFreedBytes,
                    freedCount: deletionManager.toastFreedCount,
                    onUndo: { deletionManager.undoLast() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(999)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: deletionManager.toastVisible)
        .alert(
            "Couldn’t remove photos",
            isPresented: Binding(
                get: { deletionManager.lastDeletionError != nil },
                set: { if !$0 { deletionManager.dismissLastError() } }
            )
        ) {
            Button("OK") { deletionManager.dismissLastError() }
        } message: {
            Text(deletionManager.lastDeletionError ?? "The photo library did not complete the deletion.")
        }
    }
}

extension View {
    func deletionUndoToast() -> some View {
        modifier(DeletionUndoToastModifier())
    }
}
