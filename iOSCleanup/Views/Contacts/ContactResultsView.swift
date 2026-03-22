import SwiftUI
import Contacts

struct ContactResultsView: View {
    let matches: [ContactMatch]
    @EnvironmentObject private var purchaseManager: PurchaseManager

    @State private var visibleMatches: [ContactMatch]
    @State private var showPaywall = false
    @State private var mergeError: String?

    init(matches: [ContactMatch]) {
        self.matches = matches
        _visibleMatches = State(initialValue: matches)
    }

    var body: some View {
        Group {
            if visibleMatches.isEmpty {
                EmptyStateView(title: "No Duplicates Found", icon: "person.2.fill",
                               message: "Your contacts look clean.")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if let error = mergeError {
                            Text(error)
                                .font(.duckCaption)
                                .foregroundStyle(.red)
                                .padding(.horizontal)
                        }
                        ForEach(visibleMatches) { match in
                            contactCard(match: match)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .background(Color.duckBlush.ignoresSafeArea())
            }
        }
        .navigationTitle("Duplicate Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    private func contactCard(match: ContactMatch) -> some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 12) {
                // Confidence badge
                HStack {
                    Text(confidenceLabel(match))
                        .font(.duckLabel)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(confidenceColor(match).opacity(0.15))
                        .foregroundStyle(confidenceColor(match))
                        .clipShape(Capsule())
                    Spacer()
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(Color.duckSoftPink)
                }

                // Two contacts side by side
                HStack(alignment: .top, spacing: 12) {
                    contactInfo(match.primary, label: "Keep")
                    Divider()
                    contactInfo(match.duplicate, label: "Merge")
                }

                // Action row
                HStack(spacing: 10) {
                    NavigationLink(destination: ContactMergePreviewView(match: match)
                        .environmentObject(purchaseManager)) {
                        Text("Review")
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(Color.duckRose)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.duckCream, in: Capsule())
                    }

                    Button {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        // Navigate to merge preview for actual merge action
                    } label: {
                        Text(purchaseManager.isPurchased ? "Merge" : "Merge 🔒")
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.duckPink, in: Capsule())
                    }
                }
            }
            .padding(14)
        }
    }

    private func contactInfo(_ contact: CNContact, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.duckLabel)
                .foregroundStyle(Color.duckSoftPink)
            Text(fullName(contact))
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.duckBerry)
                .lineLimit(1)
            if let phone = contact.phoneNumbers.first?.value.stringValue {
                Text(phone)
                    .font(.duckLabel)
                    .foregroundStyle(Color.duckRose)
                    .lineLimit(1)
            } else {
                Text("No phone")
                    .font(.duckLabel)
                    .foregroundStyle(Color.duckSoftPink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confidenceLabel(_ match: ContactMatch) -> String {
        switch match.confidence {
        case .certain:  return "Certain match"
        case .probable: return "Probable match"
        case .possible: return "Possible match"
        }
    }

    private func confidenceColor(_ match: ContactMatch) -> Color {
        switch match.confidence {
        case .certain:  return .green
        case .probable: return .duckOrange
        case .possible: return .gray
        }
    }

    private func fullName(_ contact: CNContact) -> String {
        [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
