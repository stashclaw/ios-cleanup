import SwiftUI

/// Sticky bottom action bar used across photo/file detail views.
/// Shows a summary label on the left and a pink pill CTA on the right.
/// When `isPaid` is true the enabled button shows a lock and opens the paywall.
struct DuckBottomActionBar: View {
    let summary: String
    let primaryLabel: String
    let primaryEnabled: Bool
    let isPaid: Bool
    let onPrimary: () -> Void
    let onShowPaywall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .font(.duckCaption)
                .foregroundStyle(Color.duckRose)
                .lineLimit(1)

            Spacer()

            Button {
                if isPaid {
                    onShowPaywall()
                } else {
                    onPrimary()
                }
            } label: {
                HStack(spacing: 6) {
                    if isPaid {
                        Image(systemName: "lock.fill")
                    }
                    Text(primaryLabel)
                }
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minHeight: 44)
                .padding(.horizontal, 20)
                .background(
                    primaryEnabled ? Color.duckPink : Color.duckSoftPink,
                    in: Capsule()
                )
            }
            .disabled(!primaryEnabled)
            .accessibilityHint(isPaid && primaryEnabled ? "Requires PhotoDuck unlock" : "")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.duckBlush)
        .overlay(alignment: .top) {
            Divider().background(Color.duckSoftPink)
        }
    }
}
