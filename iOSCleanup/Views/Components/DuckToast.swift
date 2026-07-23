import SwiftUI

/// The single toast shell used across the app. Deletion undo and list
/// reordering both render through this component so transient notices look
/// and behave identically: optional leading action, message, trailing
/// details, and an optional countdown bar for timed windows.
struct DuckToast: View {
    enum Style {
        case info        // non-destructive notices ("Moved to end of list")
        case destructive // pending deletion with an undo window
    }

    let style: Style
    let message: String
    var detail: String?          // e.g. freed bytes
    var trailingDetail: String?  // e.g. remaining seconds
    var actionLabel: String?
    var onAction: (() -> Void)?
    var progress: Double?        // remaining fraction of a timed window

    private var messageColor: Color {
        style == .destructive ? .accentPrimary : .textPrimary
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if let actionLabel, let onAction {
                    Button(action: onAction) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.duckCaption.weight(.bold))
                            Text(actionLabel)
                                .font(.duckButton)
                        }
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(Color.textSecondary.opacity(0.28))
                        .frame(width: 1, height: 34)
                        .padding(.vertical, 8)
                }

                HStack(spacing: 8) {
                    Text(message)
                        .font(.duckButton)
                        .foregroundStyle(messageColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Spacer(minLength: 8)

                    if let detail {
                        Text(detail)
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(Color.textSecondary.opacity(0.75))
                            .monospacedDigit()
                    }

                    if let trailingDetail {
                        Text(trailingDetail)
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(Color.textSecondary.opacity(0.75))
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }

            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 50, style: .continuous)
                            .fill(Color.textSecondary.opacity(0.16))

                        RoundedRectangle(cornerRadius: 50, style: .continuous)
                            .fill(Color.accentPrimary)
                            .frame(width: geo.size.width * min(max(progress, 0), 1))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 50, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 50, style: .continuous)
                .strokeBorder(style == .destructive ? Color.accentPrimary : Color.textSecondary.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.textPrimary.opacity(0.10), radius: 6, x: 0, y: 2)
        .padding(.horizontal, 16)
    }
}
