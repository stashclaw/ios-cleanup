import Contacts

actor ContactScanEngine {

    func scan() async throws -> [ContactMatch] {
        let contacts = try await fetchContacts()
        let index = phoneIndex(from: contacts)
        return findMatches(contacts: contacts, index: index)
    }

    private func fetchContacts() async throws -> [CNContact] {
        let store = CNContactStore()
        try await store.requestAccess(for: .contacts)

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        var contacts: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }
        return contacts
    }

    private func phoneIndex(from contacts: [CNContact]) -> [String: [CNContact]] {
        var index: [String: [CNContact]] = [:]
        for contact in contacts {
            for phone in contact.phoneNumbers {
                if let normalized = PhoneNormalizer.normalize(phone.value.stringValue) {
                    index[normalized, default: []].append(contact)
                }
            }
        }
        return index
    }

    private func findMatches(contacts: [CNContact], index: [String: [CNContact]]) -> [ContactMatch] {
        var matches: [ContactMatch] = []
        var matchedPairs = Set<String>()

        func pairKey(_ a: CNContact, _ b: CNContact) -> String {
            let ids = [a.identifier, b.identifier].sorted()
            return ids.joined(separator: "|")
        }

        // Phase 1: phone-based matches
        for (_, bucket) in index where bucket.count >= 2 {
            for i in 0..<bucket.count {
                for j in (i+1)..<bucket.count {
                    let a = bucket[i], b = bucket[j]
                    let key = pairKey(a, b)
                    guard matchedPairs.insert(key).inserted else { continue }

                    let (primary, duplicate) = determinePrimary(a, b)

                    var reasons: [ContactMatch.MatchReason] = [.identicalPhone]
                    let nameA = fullName(a), nameB = fullName(b)
                    let nameDist = NameMatcher.distance(nameA, nameB)

                    let confidence: ContactMatch.MatchConfidence
                    if nameDist <= 2 {
                        reasons.append(nameDist == 0 ? .sameNameDifferentFormat : .fuzzyName(distance: nameDist))
                        confidence = .certain
                    } else {
                        confidence = .probable
                    }

                    matches.append(ContactMatch(
                        id: UUID(),
                        primary: primary,
                        duplicate: duplicate,
                        confidence: confidence,
                        reasons: reasons
                    ))
                }
            }
        }

        // Phase 2: name-only fuzzy matches for unmatched contacts
        var phonematched = Set<String>()
        for match in matches {
            phonematched.insert(match.primary.identifier)
            phonematched.insert(match.duplicate.identifier)
        }

        let unmatched = contacts.filter { !phonematched.contains($0.identifier) }
        for i in 0..<unmatched.count {
            for j in (i+1)..<unmatched.count {
                let a = unmatched[i], b = unmatched[j]
                let key = pairKey(a, b)
                guard matchedPairs.insert(key).inserted else { continue }

                let nameA = fullName(a), nameB = fullName(b)
                let dist = NameMatcher.distance(nameA, nameB)
                guard dist <= 2, !nameA.isEmpty, !nameB.isEmpty else { continue }

                let (primary, duplicate) = determinePrimary(a, b)
                matches.append(ContactMatch(
                    id: UUID(),
                    primary: primary,
                    duplicate: duplicate,
                    confidence: .possible,
                    reasons: [.fuzzyName(distance: dist)]
                ))
            }
        }

        return matches
    }

    private func fullName(_ contact: CNContact) -> String {
        [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func filledFieldCount(_ contact: CNContact) -> Int {
        var count = 0
        if !contact.givenName.isEmpty { count += 1 }
        if !contact.familyName.isEmpty { count += 1 }
        if !contact.organizationName.isEmpty { count += 1 }
        if !contact.phoneNumbers.isEmpty { count += 1 }
        if !contact.emailAddresses.isEmpty { count += 1 }
        if contact.birthday != nil { count += 1 }
        if contact.imageDataAvailable { count += 1 }
        return count
    }

    private func determinePrimary(_ a: CNContact, _ b: CNContact) -> (primary: CNContact, duplicate: CNContact) {
        let countA = filledFieldCount(a)
        let countB = filledFieldCount(b)
        return countA >= countB ? (a, b) : (b, a)
    }
}
