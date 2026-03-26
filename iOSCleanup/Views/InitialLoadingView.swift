import SwiftUI

/// Full-screen loading overlay shown on first launch (no cache) while
/// Tier 1 + Tier 2 engines populate the library. Dismissed automatically
/// when HomeViewModel.isInitialScanReady flips to true.
struct InitialLoadingView: View {
    let progress: Double      // 0.0 → 1.0
    let phase: String         // human-readable status

    private let bg     = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let accent = Color(red: 0.18, green: 0.72, blue: 0.95)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Logo ─────────────────────────────────────────────────
                Image("photoduck-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 52)
                    .padding(.bottom, 48)

                // ── Progress bar ──────────────────────────────────────────
                VStack(spacing: 14) {
                    progressBar
                    phaseLabel
                }
                .padding(.horizontal, 48)

                Spacer()

                // ── Subtle footer ─────────────────────────────────────────
                Text("Scanning runs once. Your photos never leave your device.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.25))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 36)
            }
        }
    }

    // MARK: - Sub-views

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 6)

                // Fill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(12, geo.size.width * progress), height: 6)
                    .animation(.easeInOut(duration: 0.4), value: progress)
            }
        }
        .frame(height: 6)
    }

    private var phaseLabel: some View {
        HStack {
            Text(phase)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.45))
                .animation(.easeInOut(duration: 0.3), value: phase)
            Spacer()
            Text("\(Int(progress * 100))%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(accent.opacity(0.8))
                .animation(.easeInOut(duration: 0.4), value: progress)
        }
    }
}
