import SwiftUI
import StoreKit

struct SettingsView: View {
    @ObservedObject var viewModel: HomeViewModel
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @AppStorage("hasOnboarded") private var hasOnboarded = true
    @Environment(\.dismiss) private var dismiss

    @State private var showRescanConfirm = false
    @State private var decisionCount: Int = 0
    @State private var skippedGroupCount: Int = 0

    private let bg    = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let card  = Color(white: 1, opacity: 0.05)
    private let stroke = Color(white: 1, opacity: 0.08)

    var body: some View {
        NavigationStack {
            ZStack {
                bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        premiumSection
                        actionsSection
                        devSection
                        appInfoSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    // MARK: - Premium status

    private var premiumSection: some View {
        settingsCard {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(purchaseManager.isPurchased
                          ? LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.67), Color(red: 0.45, green: 0.4, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                          : LinearGradient(colors: [Color.white.opacity(0.15), Color.white.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: purchaseManager.isPurchased ? "checkmark.seal.fill" : "lock.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(purchaseManager.isPurchased ? "Premium Unlocked" : "Free Plan")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(purchaseManager.isPurchased
                         ? AppConfig.unlockPremium ? "Dev override active" : "Full access to all features"
                         : "Upgrade to unlock all features")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer()
                if purchaseManager.isPurchased {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.29, green: 0.85, blue: 0.6))
                }
            }
            .padding(16)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        settingsCard {
            VStack(spacing: 0) {
                settingsRow(icon: "arrow.counterclockwise.circle", iconColor: Color(red: 0.45, green: 0.4, blue: 1), title: "Restore Purchase") {
                    Task { await purchaseManager.restore() }
                }
                Divider().overlay(stroke)
                settingsRow(icon: "hand.raised.fill", iconColor: Color(red: 0.18, green: 0.72, blue: 0.95), title: "Privacy Policy") {
                    if let url = URL(string: "https://photoduck.app/privacy") {
                        UIApplication.shared.open(url)
                    }
                }
                Divider().overlay(stroke)
                // Full rescan — bypasses incremental mode and scans entire library.
                Button {
                    showRescanConfirm = true
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Full Library Rescan")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                                if let date = viewModel.lastScanDate {
                                    Text("Last scanned \(date.formatted(.relative(presentation: .named)))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.white.opacity(0.35))
                                } else {
                                    Text("No scan history")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.white.opacity(0.35))
                                }
                            }
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67))
                                .frame(width: 28)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.2))
                    }
                    .padding(16)
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    "Full Library Rescan",
                    isPresented: $showRescanConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Rescan Entire Library", role: .destructive) {
                        dismiss()
                        Task { await viewModel.fullRescan() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This clears all existing results and rescans your entire library from scratch. Use the regular scan for checking only new photos.")
                }
            }
        }
    }

    // MARK: - Dev tools

    @ViewBuilder
    private var devSection: some View {
        if AppConfig.unlockPremium {
            VStack(alignment: .leading, spacing: 8) {
                Text("Developer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .padding(.leading, 4)

                settingsCard {
                    VStack(spacing: 0) {
                        HStack {
                            Label {
                                Text("Premium Override")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                            } icon: {
                                Image(systemName: "wrench.and.screwdriver.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color(red: 0.98, green: 0.57, blue: 0.24))
                                    .frame(width: 28)
                            }
                            Spacer()
                            Text("ON")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(red: 0.29, green: 0.85, blue: 0.6))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color(red: 0.29, green: 0.85, blue: 0.6).opacity(0.15), in: Capsule())
                        }
                        .padding(16)
                        Divider().overlay(stroke)
                        settingsRow(icon: "arrow.uturn.left.circle", iconColor: .red, title: "Reset Onboarding") {
                            hasOnboarded = false
                            dismiss()
                        }
                        Divider().overlay(stroke)
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Training Decisions")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white)
                                    Text("\(decisionCount) decision\(decisionCount == 1 ? "" : "s") recorded")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.white.opacity(0.35))
                                }
                            } icon: {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color(red: 0.45, green: 0.4, blue: 1))
                                    .frame(width: 28)
                            }
                            Spacer()
                        }
                        .padding(16)
                        Divider().overlay(stroke)
                        settingsRow(icon: "trash.circle", iconColor: .red, title: "Clear Decision History") {
                            Task {
                                await UserDecisionStore.shared.clearAll()
                                decisionCount = await UserDecisionStore.shared.decisionCount()
                            }
                        }
                        Divider().overlay(stroke)
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Skipped Groups")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white)
                                    Text("\(skippedGroupCount) group\(skippedGroupCount == 1 ? "" : "s") hidden from review")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.white.opacity(0.35))
                                }
                            } icon: {
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color(red: 0.98, green: 0.57, blue: 0.24))
                                    .frame(width: 28)
                            }
                            Spacer()
                            if skippedGroupCount > 0 {
                                Button("Clear") {
                                    GroupReviewViewModel.clearSkippedGroups()
                                    skippedGroupCount = 0
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.red)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .task {
                decisionCount     = await UserDecisionStore.shared.decisionCount()
                skippedGroupCount = GroupReviewViewModel.skippedGroupCount
            }
        }
    }

    // MARK: - App info

    private var appInfoSection: some View {
        settingsCard {
            VStack(spacing: 0) {
                HStack {
                    Text("Version")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .padding(16)
                Divider().overlay(stroke)
                HStack {
                    Text("App")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Spacer()
                    Text("PhotoDuck")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .padding(16)
            }
        }
    }

    // MARK: - Reusable components

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(stroke))
    }

    private func settingsRow(icon: String, iconColor: Color, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                } icon: {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(iconColor)
                        .frame(width: 28)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.2))
            }
            .padding(16)
        }
        .buttonStyle(.plain)
    }
}
