import SwiftUI

// MARK: - Scanning Banner

/// Compact inline banner shown at the top of results views while a scan is still running.
struct ScanningBanner: View {
    let message: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().tint(color).scaleEffect(0.75)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(color)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Empty State

/// iOS 16-compatible replacement for ContentUnavailableView (which requires iOS 17).
struct EmptyStateView: View {
    let title: String
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }
}
