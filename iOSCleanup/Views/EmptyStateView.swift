import SwiftUI

/// iOS 16-compatible replacement for ContentUnavailableView (which requires iOS 17).
struct EmptyStateView: View {
    /// Celebration is for genuinely good outcomes ("your library is clean").
    /// Neutral is for filters, permission problems, and anything where a
    /// "Clean outcome / Ready" badge would be misleading.
    enum Style {
        case celebration
        case neutral
    }

    let title: String
    let icon: String
    let message: String
    var style: Style = .celebration
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        DuckCard {
            VStack(spacing: 16) {
                if style == .celebration {
                    StatusBadge(title: "Clean outcome", accent: .textPrimary)
                        .accessibilityHidden(true)
                }

                PhotoDuckMascotArt(size: 120)
                    .shadow(color: .accentPrimary.opacity(0.18), radius: 16, x: 0, y: 10)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.duckTitle)
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    if !message.isEmpty {
                        Text(message)
                            .font(.duckBody)
                            .foregroundStyle(Color.textPrimary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if style == .celebration {
                    Label("Ready", systemImage: icon)
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.backgroundBlush, in: Capsule())
                        .accessibilityLabel("Status: ready")
                }

                if let actionTitle, let action {
                    DuckPrimaryButton(title: actionTitle, action: action)
                        .padding(.horizontal, 12)
                }
            }
            .padding(20)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.backgroundBlush)
    }
}
