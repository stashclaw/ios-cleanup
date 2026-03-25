import SwiftUI
import Contacts

struct ContactResultsView: View {
    let matches: [ContactMatch]
    @EnvironmentObject private var purchaseManager: PurchaseManager

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)

    private var certain:  [ContactMatch] { matches.filter { $0.confidence == .certain } }
    private var probable: [ContactMatch] { matches.filter { $0.confidence == .probable } }
    private var possible: [ContactMatch] { matches.filter { $0.confidence == .possible } }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            if matches.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color(red: 0.4, green: 0.8, blue: 0.6).opacity(0.6))
                    Text("No Duplicate Contacts")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Your contacts look clean.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        if !certain.isEmpty {
                            section(title: "Certain", accent: Color(red: 1, green: 0.42, blue: 0.67), items: certain)
                        }
                        if !probable.isEmpty {
                            section(title: "Probable", accent: Color(red: 0.98, green: 0.57, blue: 0.24), items: probable)
                        }
                        if !possible.isEmpty {
                            section(title: "Possible", accent: Color(red: 0.45, green: 0.4, blue: 1), items: possible)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
        }
        .navigationTitle("Duplicate Contacts")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func section(title: String, accent: Color, items: [ContactMatch]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.15), in: Capsule())
                Text("\(items.count)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()
            }

            ForEach(items) { match in
                NavigationLink(destination: ContactMergePreviewView(match: match)
                    .environmentObject(purchaseManager)) {
                    ContactMatchRow(match: match, accent: accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Match Row

private struct ContactMatchRow: View {
    let match: ContactMatch
    let accent: Color

    var body: some View {
        HStack(spacing: 14) {
            // Avatar placeholder
            ZStack {
                Circle()
                    .fill(accent.opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(initials(match.primary))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(fullName(match.primary))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(fullName(match.duplicate))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                if !match.reasons.isEmpty {
                    Text(reasonSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.2))
        }
        .padding(14)
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(white: 1, opacity: 0.07)))
    }

    private var reasonSummary: String {
        match.reasons.compactMap { reason -> String? in
            switch reason {
            case .identicalPhone:           return "Same phone"
            case .identicalEmail:           return "Same email"
            case .sameNameDifferentFormat:  return "Same name"
            case .fuzzyName(let d):         return "Similar name (±\(d))"
            case .semanticOrganization:     return "Similar organization"
            }
        }.joined(separator: " · ")
    }

    private func fullName(_ contact: CNContact) -> String {
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? contact.organizationName : name
    }

    private func initials(_ contact: CNContact) -> String {
        let g = contact.givenName.first.map(String.init) ?? ""
        let f = contact.familyName.first.map(String.init) ?? ""
        let combined = g + f
        return combined.isEmpty ? "?" : combined.uppercased()
    }
}
