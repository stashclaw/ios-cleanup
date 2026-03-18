import SwiftUI

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
