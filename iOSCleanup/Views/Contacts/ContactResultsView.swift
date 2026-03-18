import SwiftUI
import Contacts

struct ContactResultsView: View {
    let matches: [ContactMatch]

    private var certain: [ContactMatch]  { matches.filter { $0.confidence == .certain } }
    private var probable: [ContactMatch] { matches.filter { $0.confidence == .probable } }
    private var possible: [ContactMatch] { matches.filter { $0.confidence == .possible } }

    var body: some View {
        Group {
            if matches.isEmpty {
                EmptyStateView(title: "No Duplicates Found", icon: "person.2.fill", message: "Your contacts look clean.")
            } else {
                List {
                    if !certain.isEmpty {
                        Section("Certain (\(certain.count))") {
                            ForEach(certain) { match in
                                NavigationLink(destination: ContactMergePreviewView(match: match)) {
                                    ContactMatchRow(match: match)
                                }
                            }
                        }
                    }
                    if !probable.isEmpty {
                        Section("Probable (\(probable.count))") {
                            ForEach(probable) { match in
                                NavigationLink(destination: ContactMergePreviewView(match: match)) {
                                    ContactMatchRow(match: match)
                                }
                            }
                        }
                    }
                    if !possible.isEmpty {
                        Section("Possible (\(possible.count))") {
                            ForEach(possible) { match in
                                NavigationLink(destination: ContactMergePreviewView(match: match)) {
                                    ContactMatchRow(match: match)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Duplicate Contacts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Row

private struct ContactMatchRow: View {
    let match: ContactMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(fullName(match.primary))
                    .font(.headline)
                Spacer()
                confidenceBadge
            }
            Text(fullName(match.duplicate))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !match.reasons.isEmpty {
                Text(reasonSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var confidenceBadge: some View {
        let (label, color): (String, Color) = switch match.confidence {
        case .certain:  ("Certain", .green)
        case .probable: ("Probable", .orange)
        case .possible: ("Possible", .secondary)
        }
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var reasonSummary: String {
        match.reasons.compactMap { reason -> String? in
            switch reason {
            case .identicalPhone:        return "Same phone"
            case .identicalEmail:        return "Same email"
            case .sameNameDifferentFormat: return "Same name"
            case .fuzzyName(let d):      return "Similar name (±\(d))"
            }
        }.joined(separator: " · ")
    }

    private func fullName(_ contact: CNContact) -> String {
        [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
