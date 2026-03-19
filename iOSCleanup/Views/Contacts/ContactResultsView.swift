import SwiftUI
import Contacts

struct ContactResultsView: View {
    let matches: [ContactMatch]
    @EnvironmentObject private var purchaseManager: PurchaseManager

    private var certain: [ContactMatch]  { matches.filter { $0.confidence == .certain } }
    private var probable: [ContactMatch] { matches.filter { $0.confidence == .probable } }
    private var possible: [ContactMatch] { matches.filter { $0.confidence == .possible } }

    var body: some View {
        Group {
            if matches.isEmpty {
                EmptyStateView(title: "No Duplicates Found", icon: "person.2.fill",
                               message: "Your contacts look clean.")
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        if !certain.isEmpty {
                            section(title: "Certain (\(certain.count))", items: certain)
                        }
                        if !probable.isEmpty {
                            section(title: "Probable (\(probable.count))", items: probable)
                        }
                        if !possible.isEmpty {
                            section(title: "Possible (\(possible.count))", items: possible)
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
    }

    private func section(title: String, items: [ContactMatch]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DuckSectionHeader(title: title)
            ForEach(items) { match in
                DuckCard {
                    NavigationLink(destination: ContactMergePreviewView(match: match)
                        .environmentObject(purchaseManager)) {
                        ContactMatchRow(match: match)
                            .padding(14)
                    }
                }
            }
        }
    }
}

// MARK: - Row

private struct ContactMatchRow: View {
    let match: ContactMatch

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(fullName(match.primary))
                    .font(.duckBody)
                    .foregroundStyle(Color.duckBerry)
                Text(fullName(match.duplicate))
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
                if !match.reasons.isEmpty {
                    Text(reasonSummary)
                        .font(.duckLabel)
                        .foregroundStyle(Color.duckSoftPink)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                confidenceBadge
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(Color.duckSoftPink)
            }
        }
    }

    private var confidenceBadge: some View {
        let (label, color): (String, Color) = switch match.confidence {
        case .certain:  ("Certain", Color.duckPink)
        case .probable: ("Probable", Color.duckOrange)
        case .possible: ("Possible", Color.duckSoftPink)
        }
        return Text(label)
            .font(.duckLabel)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var reasonSummary: String {
        match.reasons.compactMap { reason -> String? in
            switch reason {
            case .identicalPhone:           return "Same phone"
            case .identicalEmail:           return "Same email"
            case .sameNameDifferentFormat:  return "Same name"
            case .fuzzyName(let d):         return "Similar name (±\(d))"
            }
        }.joined(separator: " · ")
    }

    private func fullName(_ contact: CNContact) -> String {
        [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
