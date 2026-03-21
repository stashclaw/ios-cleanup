import SwiftUI

/// iOS 16-compatible replacement for ContentUnavailableView (which requires iOS 17).
struct EmptyStateView: View {
    let title: String
    let icon: String
    let message: String

    var body: some View {
        DuckCard {
            VStack(spacing: 16) {
                StatusBadge(title: "Clean outcome", accent: .duckPink)

                PhotoDuckAssetImage(
                    assetNames: ["photoduck_mascot", "photoduck_logo"],
                    fallback: { PhotoDuckMascotFallback(size: 88) }
                )
                .frame(width: 120, height: 120)
                .shadow(color: .duckPink.opacity(0.18), radius: 16, x: 0, y: 10)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.duckTitle)
                        .foregroundStyle(Color.duckBerry)
                        .multilineTextAlignment(.center)

                    if !message.isEmpty {
                        Text(message)
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }

                Label("Ready", systemImage: icon)
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.photoduckBlushBackground, in: Capsule())
            }
            .padding(20)
        }
    }
}
