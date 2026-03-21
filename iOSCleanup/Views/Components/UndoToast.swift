import SwiftUI

// Floating toast that appears after a deletion is scheduled.
// PhotoKit deletions are not reversible through the public API, so tapping Undo here
// simply cancels the deferred commit window before the change is finalized.
struct UndoToast: View {
    let toastID: UUID
    let freedBytes: Int64
    let freedCount: Int
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @State private var progress: Double = 1.0

    private var freedLabel: String {
        ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)
    }

    private var freedCountLabel: String {
        "\(freedCount) photo\(freedCount == 1 ? "" : "s")"
    }

    private var remainingSeconds: Int {
        max(0, Int(ceil(progress * 10)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    onUndo()
                    onDismiss()
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
                    .fill(Color.duckSoftPink)
                    .frame(width: 1, height: 34)
                    .padding(.vertical, 8)

                Button {
                    onDismiss()
                } label: {
                    HStack(spacing: 8) {
                        Text("Freed \(freedCountLabel)")
                            .font(.duckButton)
                            .foregroundStyle(Color.duckPink)

                        Text("✦")
                            .font(.duckButton)
                            .foregroundStyle(Color.duckYellow)

                        Spacer(minLength: 8)

                        Text(freedLabel)
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(Color.duckRose.opacity(0.75))
                            .monospacedDigit()

                        Text("\(remainingSeconds)s")
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(Color.duckRose.opacity(0.75))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 50, style: .continuous)
                        .fill(Color.duckSoftPink.opacity(0.35))

                    RoundedRectangle(cornerRadius: 50, style: .continuous)
                        .fill(Color.duckSoftPink)
                        .frame(width: geo.size.width * progress)
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
        .padding(.horizontal, 24)
        .task(id: toastID) {
            progress = 1
            withAnimation(.linear(duration: 10)) {
                progress = 0
            }

            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}
