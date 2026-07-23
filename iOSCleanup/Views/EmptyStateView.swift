import SwiftUI

/// iOS 16-compatible replacement for ContentUnavailableView (which requires iOS 17).
struct EmptyStateView: View {
    let title: String
    let icon: String
    let message: String

    var body: some View {
        DuckCard {
            VStack(spacing: 16) {
                StatusBadge(title: "Clean outcome", accent: .duckBerry)
                    .accessibilityHidden(true)

                PhotoDuckMascotArt(size: 120)
                    .shadow(color: .duckPink.opacity(0.18), radius: 16, x: 0, y: 10)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.duckTitle)
                        .foregroundStyle(Color.duckBerry)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    if !message.isEmpty {
                        Text(message)
                            .font(.duckBody)
                            .foregroundStyle(Color.duckBerry)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Label("Ready", systemImage: icon)
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.duckBerry)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.duckBlush, in: Capsule())
                    .accessibilityLabel("Status: ready")
            }
            .padding(20)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.duckBlush)
    }
}
