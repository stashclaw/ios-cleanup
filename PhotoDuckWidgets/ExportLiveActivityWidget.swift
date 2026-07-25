import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen / Dynamic Island UI for a running export.
/// Self-contained on purpose: widget extensions don't share the app's asset
/// catalog, so brand colors are literal values here.
struct ExportLiveActivityWidget: Widget {
    private static let duckPink = Color(red: 0.973, green: 0.373, blue: 0.639)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhotoDuckExportActivityAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: phaseSymbol(context.state))
                        .foregroundStyle(Self.duckPink)
                        .padding(.leading, 4)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percentLabel(context.state))
                        .font(.headline)
                        .foregroundStyle(Self.duckPink)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(phaseTitle(context.state))
                            .font(.caption.weight(.semibold))
                        Label(
                            context.attributes.destinationName,
                            systemImage: "folder.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        Text(context.state.statusLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ProgressView(value: clampedFraction(context.state))
                            .tint(Self.duckPink)
                    }
                }
            } compactLeading: {
                Image(systemName: phaseSymbol(context.state))
                    .foregroundStyle(Self.duckPink)
                    .accessibilityHidden(true)
            } compactTrailing: {
                Text(percentLabel(context.state))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Self.duckPink)
            } minimal: {
                Image(systemName: phaseSymbol(context.state))
                    .foregroundStyle(Self.duckPink)
                    .accessibilityLabel(phaseTitle(context.state))
            }
            .keylineTint(Self.duckPink)
        }
    }

    @ViewBuilder
    private func lockScreenView(
        _ context: ActivityViewContext<PhotoDuckExportActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: phaseSymbol(context.state))
                    .foregroundStyle(Self.duckPink)
                    .accessibilityHidden(true)
                Text(phaseTitle(context.state))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(percentLabel(context.state))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Self.duckPink)
            }

            ProgressView(value: clampedFraction(context.state))
                .tint(Self.duckPink)

            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .accessibilityHidden(true)
                Text(context.attributes.destinationName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // Without this, a suspended or stalled export renders exactly
                // like a healthy one — a progress bar frozen for hours with no
                // explanation.
                Text(
                    context.isStale
                        ? "Not responding — open PhotoDuck"
                        : context.state.statusLine
                )
                .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(phaseTitle(context.state)), \(context.state.statusLine), \(percentLabel(context.state))"
        )
    }

    private func clampedFraction(
        _ state: PhotoDuckExportActivityAttributes.ContentState
    ) -> Double {
        min(max(state.overallFraction, 0), 1)
    }

    private func percentLabel(
        _ state: PhotoDuckExportActivityAttributes.ContentState
    ) -> String {
        "\(Int((clampedFraction(state) * 100).rounded()))%"
    }

    private func phaseTitle(
        _ state: PhotoDuckExportActivityAttributes.ContentState
    ) -> String {
        switch state.phase {
        case .exporting:
            return "Exporting selected items"
        case .paused:
            return "Export paused"
        case .finished:
            return "Export complete"
        case .completedWithFailures:
            return "Export complete with issues"
        case .cancelled:
            return "Export cancelled"
        case .failed:
            return "Export couldn’t finish"
        }
    }

    private func phaseSymbol(
        _ state: PhotoDuckExportActivityAttributes.ContentState
    ) -> String {
        switch state.phase {
        case .exporting:
            return "externaldrive.fill.badge.checkmark"
        case .paused:
            return "pause.circle.fill"
        case .finished:
            return "checkmark.circle.fill"
        case .completedWithFailures:
            return "exclamationmark.circle.fill"
        case .cancelled:
            return "xmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}
