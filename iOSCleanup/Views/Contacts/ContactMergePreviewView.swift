import SwiftUI
import Contacts

struct ContactMergePreviewView: View {
    let match: ContactMatch
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    @State private var isMerging = false
    @State private var isMerged = false
    @State private var mergeError: String?
    @State private var showPaywall = false

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let accent = Color(red: 0.4, green: 0.8, blue: 0.6)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            if isMerged {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(accent)
                    Text("Contacts Merged")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text("The duplicate has been removed.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        headerCard
                        diffGrid
                        mergeButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
        }
        .navigationTitle("Merge Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Header card

    private var headerCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Keep", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(displayName(match.primary))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.4))

            VStack(alignment: .trailing, spacing: 4) {
                Label("Remove", systemImage: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67))
                Text(displayName(match.duplicate))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(white: 1, opacity: 0.07)))
    }

    // MARK: - Two-column diff grid

    private var diffGrid: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                columnHeader("Primary (Keep)", color: accent)
                Divider().frame(width: 1).background(Color(white: 1, opacity: 0.08))
                columnHeader("Duplicate (Merge)", color: Color(red: 1, green: 0.42, blue: 0.67))
            }
            .frame(height: 36)

            ForEach(diffRows, id: \.label) { row in
                Divider().background(Color(white: 1, opacity: 0.06))
                HStack(spacing: 0) {
                    fieldCell(row.primaryValue, highlight: row.addedFromPrimary ? .green : nil)
                    Divider().frame(width: 1).background(Color(white: 1, opacity: 0.06))
                    fieldCell(row.duplicateValue,
                              highlight: row.addedFromDuplicate ? .green : row.droppedFromDuplicate ? .red : nil,
                              strikethrough: row.droppedFromDuplicate)
                }
            }
        }
        .background(Color(white: 1, opacity: 0.04), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(white: 1, opacity: 0.07)))
    }

    private func columnHeader(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
    }

    private func fieldCell(
        _ value: String?,
        highlight: Color? = nil,
        strikethrough: Bool = false
    ) -> some View {
        Group {
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(highlight != nil ? highlight! : Color.white.opacity(0.75))
                    .strikethrough(strikethrough, color: Color(red: 1, green: 0.42, blue: 0.67))
            } else {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            highlight.map { $0.opacity(0.08) } ?? Color.clear,
            in: Rectangle()
        )
    }

    // MARK: - Merge button

    private var mergeButton: some View {
        VStack(spacing: 10) {
            if let error = mergeError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67))
                    .multilineTextAlignment(.center)
            }

            Button {
                guard purchaseManager.isPurchased else { showPaywall = true; return }
                Task { await merge() }
            } label: {
                Group {
                    if isMerging {
                        ProgressView().tint(.white)
                    } else {
                        Label(
                            purchaseManager.isPurchased ? "Merge Contacts" : "Merge Contacts 🔒",
                            systemImage: "person.2.fill"
                        )
                        .font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(isMerging)
        }
    }

    // MARK: - Merge logic

    private func merge() async {
        isMerging = true
        defer { isMerging = false }

        let store = CNContactStore()
        let request = CNSaveRequest()

        guard let mutablePrimary = match.primary.mutableCopy() as? CNMutableContact else {
            mergeError = "Could not prepare contact for editing."
            return
        }
        let duplicate = match.duplicate

        // Phone numbers: add any from duplicate not already in primary
        let existingPhones = Set(mutablePrimary.phoneNumbers.map { $0.value.stringValue })
        let newPhones = duplicate.phoneNumbers.filter { !existingPhones.contains($0.value.stringValue) }
        mutablePrimary.phoneNumbers += newPhones

        // Email addresses
        let existingEmails = Set(mutablePrimary.emailAddresses.map { $0.value as String })
        let newEmails = duplicate.emailAddresses.filter { !existingEmails.contains($0.value as String) }
        mutablePrimary.emailAddresses += newEmails

        // Fill empty scalar fields from duplicate
        if mutablePrimary.organizationName.isEmpty { mutablePrimary.organizationName = duplicate.organizationName }
        if mutablePrimary.birthday == nil           { mutablePrimary.birthday = duplicate.birthday }

        request.update(mutablePrimary)

        guard let mutableDuplicate = duplicate.mutableCopy() as? CNMutableContact else {
            mergeError = "Could not prepare duplicate for deletion."
            return
        }
        request.delete(mutableDuplicate)

        do {
            try store.execute(request)
            isMerged = true
        } catch {
            mergeError = error.localizedDescription
        }
    }

    // MARK: - Diff rows

    private struct DiffRow {
        let label: String
        let primaryValue: String?
        let duplicateValue: String?
        var addedFromPrimary: Bool = false
        var addedFromDuplicate: Bool = false
        var droppedFromDuplicate: Bool = false
    }

    private var diffRows: [DiffRow] {
        let p = match.primary, d = match.duplicate
        return [
            DiffRow(label: "Given Name",   primaryValue: p.givenName,        duplicateValue: d.givenName),
            DiffRow(label: "Family Name",  primaryValue: p.familyName,       duplicateValue: d.familyName),
            DiffRow(label: "Organization", primaryValue: p.organizationName, duplicateValue: d.organizationName,
                    addedFromPrimary: !p.organizationName.isEmpty && d.organizationName.isEmpty,
                    droppedFromDuplicate: p.organizationName.isEmpty && !d.organizationName.isEmpty),
            DiffRow(label: "Phone",
                    primaryValue: p.phoneNumbers.first?.value.stringValue,
                    duplicateValue: d.phoneNumbers.first?.value.stringValue,
                    addedFromDuplicate: p.phoneNumbers.isEmpty && !d.phoneNumbers.isEmpty),
            DiffRow(label: "Email",
                    primaryValue: p.emailAddresses.first?.value as? String,
                    duplicateValue: d.emailAddresses.first?.value as? String,
                    addedFromDuplicate: p.emailAddresses.isEmpty && !d.emailAddresses.isEmpty),
        ]
    }

    private func displayName(_ contact: CNContact) -> String {
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? contact.organizationName : name
    }
}
