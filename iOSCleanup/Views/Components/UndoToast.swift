import SwiftUI

// Floating toast that appears after a deletion is scheduled.
// PhotoKit deletions are not reversible through the public API, so tapping Undo here
// simply cancels the deferred commit window before the change is finalized.
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
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button {
                        onUndo()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.duckCaption.weight(.bold))
                            Text("Undo")
                                .font(.duckButton)
                        }
                        .foregroundStyle(Color.duckRose)
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(Color.duckRose.opacity(0.28))
                        .frame(width: 1, height: 34)
                        .padding(.vertical, 8)

                    HStack(spacing: 8) {
                        Text("Removing \(freedCountLabel)")
                            .font(.duckButton)
                            .foregroundStyle(Color.duckPink)

                        Text("✦")
                            .font(.duckButton)
                            .foregroundStyle(Color.duckYellow)
                            .accessibilityHidden(true)

                        Spacer(minLength: 8)

                        Text(freedLabel)
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(Color.duckRose.opacity(0.75))
                            .monospacedDigit()

                        Text("\(remainingSeconds(at: context.date))s")
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(Color.duckRose.opacity(0.75))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 50, style: .continuous)
                            .fill(Color.duckRose.opacity(0.16))

                        RoundedRectangle(cornerRadius: 50, style: .continuous)
                            .fill(Color.duckPink)
                            .frame(width: geo.size.width * progress(at: context.date))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .background(Color.duckCream, in: RoundedRectangle(cornerRadius: 50, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 50, style: .continuous)
                    .strokeBorder(Color.duckPink, lineWidth: 1)
            )
            .shadow(color: Color.duckPink.opacity(0.15), radius: 12, x: 0, y: 4)
            .padding(.horizontal, 16)
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
