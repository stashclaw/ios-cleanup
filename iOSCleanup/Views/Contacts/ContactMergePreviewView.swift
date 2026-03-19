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

    var body: some View {
        Group {
            if isMerged {
                EmptyStateView(title: "Merged!", icon: "checkmark.circle.fill", message: "")
                    .tint(.green)
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        headerLabel
                        diffGrid
                        mergeButton
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Merge Preview")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Header

    private var headerLabel: some View {
        VStack(spacing: 6) {
            Text("Keep primary, merge duplicate into it")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 4) {
                Text(fullName(match.primary)).font(.headline)
                Image(systemName: "arrow.left").foregroundStyle(.blue)
                Text(fullName(match.duplicate)).font(.headline).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Two-column diff grid

    private var diffGrid: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                columnHeader("Primary (Keep)", color: .blue)
                columnHeader("Duplicate (Merge)", color: .secondary)
            }
            Divider()

            // Field rows
            ForEach(diffRows, id: \.label) { row in
                HStack(spacing: 0) {
                    fieldCell(row.primaryValue, added: row.addedFromPrimary)
                    Divider()
                    fieldCell(row.duplicateValue, added: row.addedFromDuplicate, dropped: row.droppedFromDuplicate)
                }
                Divider()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(UIColor.separator))
        )
    }

    private func columnHeader(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(color.opacity(0.08))
    }

    private func fieldCell(_ value: String?, added: Bool = false, dropped: Bool = false) -> some View {
        Group {
            if let value, !value.isEmpty {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(added ? .green : dropped ? .red : .primary)
                    .strikethrough(dropped)
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(added ? Color.green.opacity(0.08) : dropped ? Color.red.opacity(0.08) : Color.clear)
    }

    // MARK: - Merge button

    private var mergeButton: some View {
        VStack(spacing: 12) {
            if let error = mergeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(action: {
                guard purchaseManager.isPurchased else { showPaywall = true; return }
                Task { await merge() }
            }) {
                Group {
                    if isMerging {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Label(
                            purchaseManager.isPurchased ? "Merge Contacts" : "Merge Contacts 🔒",
                            systemImage: "person.2.fill"
                        )
                        .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
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
        let mutablePrimary = match.primary.mutableCopy() as! CNMutableContact
        let duplicate = match.duplicate

        // Merge fields: phone numbers
        let existingPhones = Set(mutablePrimary.phoneNumbers.map { $0.value.stringValue })
        let newPhones = duplicate.phoneNumbers.filter { !existingPhones.contains($0.value.stringValue) }
        mutablePrimary.phoneNumbers += newPhones

        // Email addresses
        let existingEmails = Set(mutablePrimary.emailAddresses.map { $0.value as String })
        let newEmails = duplicate.emailAddresses.filter { !existingEmails.contains($0.value as String) }
        mutablePrimary.emailAddresses += newEmails

        // Fill empty fields
        if mutablePrimary.organizationName.isEmpty { mutablePrimary.organizationName = duplicate.organizationName }
        if mutablePrimary.birthday == nil { mutablePrimary.birthday = duplicate.birthday }

        request.update(mutablePrimary)
        request.delete(duplicate.mutableCopy() as! CNMutableContact)

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

    private func fullName(_ contact: CNContact) -> String {
        [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
