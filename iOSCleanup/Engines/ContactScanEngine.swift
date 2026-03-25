import Contacts
import NaturalLanguage

actor ContactScanEngine {

    func scan() async throws -> [ContactMatch] {
        let contacts = try await fetchContacts()
        let index = phoneIndex(from: contacts)
        return findMatches(contacts: contacts, index: index)
    }

    // MARK: - Fetch

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
            CNContactImageDataAvailableKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        var contacts: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }
        return contacts
    }

    // MARK: - Phone index

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

    // MARK: - Match finding

    private func findMatches(contacts: [CNContact], index: [String: [CNContact]]) -> [ContactMatch] {
        var matches: [ContactMatch] = []
        var matchedPairs = Set<String>()

        func pairKey(_ a: CNContact, _ b: CNContact) -> String {
            [a.identifier, b.identifier].sorted().joined(separator: "|")
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

        // Phase 2: name-only fuzzy + semantic organization matches for unmatched contacts
        var phoneMatched = Set<String>()
        for match in matches {
            phoneMatched.insert(match.primary.identifier)
            phoneMatched.insert(match.duplicate.identifier)
        }

        let unmatched = contacts.filter { !phoneMatched.contains($0.identifier) }
        for i in 0..<unmatched.count {
            for j in (i+1)..<unmatched.count {
                let a = unmatched[i], b = unmatched[j]
                let key = pairKey(a, b)
                guard matchedPairs.insert(key).inserted else { continue }

                let nameA = fullName(a), nameB = fullName(b)
                let dist = NameMatcher.distance(nameA, nameB)

                if dist <= 2, !nameA.isEmpty, !nameB.isEmpty {
                    let (primary, duplicate) = determinePrimary(a, b)
                    matches.append(ContactMatch(
                        id: UUID(),
                        primary: primary,
                        duplicate: duplicate,
                        confidence: .possible,
                        reasons: [.fuzzyName(distance: dist)]
                    ))
                    continue
                }

                // Phase 2b: semantic org name matching (iOS 17+)
                if #available(iOS 17, *) {
                    let orgA = a.organizationName, orgB = b.organizationName
                    if !orgA.isEmpty, !orgB.isEmpty, orgA != orgB {
                        let sim = semanticSimilarity(org1: orgA, org2: orgB)
                        if sim > 0.75 {
                            let (primary, duplicate) = determinePrimary(a, b)
                            // Also check if names are close enough (or both empty) to warrant surfacing.
                            let nameMatch = nameA.isEmpty && nameB.isEmpty
                                || (!nameA.isEmpty && !nameB.isEmpty && NameMatcher.distance(nameA, nameB) <= 4)
                            if nameMatch {
                                matches.append(ContactMatch(
                                    id: UUID(),
                                    primary: primary,
                                    duplicate: duplicate,
                                    confidence: .possible,
                                    reasons: [.semanticOrganization]
                                ))
                            }
                        }
                    }
                }
            }
        }

        return matches
    }

    // MARK: - NLEmbedding semantic similarity (iOS 17+)

    /// Computes cosine similarity between two organization name embeddings.
    /// Returns a value in [0, 1] — 1 is identical, 0 is orthogonal.
    @available(iOS 17, *)
    private func semanticSimilarity(org1: String, org2: String) -> Float {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return 0 }

        // Tokenize each org name and average its token vectors.
        func averageVector(for text: String) -> [Double]? {
            let tokens = text
                .lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .flatMap { $0.components(separatedBy: .punctuationCharacters) }
                .filter { !$0.isEmpty }

            var sum: [Double]? = nil
            var count = 0
            for token in tokens {
                guard let vec = embedding.vector(for: token) else { continue }
                if sum == nil { sum = Array(repeating: 0, count: vec.count) }
                for (idx, val) in vec.enumerated() {
                    sum![idx] += val
                }
                count += 1
            }
            guard let s = sum, count > 0 else { return nil }
            return s.map { $0 / Double(count) }
        }

        guard let v1 = averageVector(for: org1), let v2 = averageVector(for: org2),
              v1.count == v2.count else { return 0 }

        let dot = zip(v1, v2).reduce(0.0) { $0 + $1.0 * $1.1 }
        let mag1 = sqrt(v1.reduce(0.0) { $0 + $1 * $1 })
        let mag2 = sqrt(v2.reduce(0.0) { $0 + $1 * $1 })
        guard mag1 > 0, mag2 > 0 else { return 0 }
        let cosine = dot / (mag1 * mag2)
        // Clamp to [0, 1] — cosine can be slightly negative for unrelated terms.
        return Float(max(0, min(1, cosine)))
    }

    // MARK: - Helpers

    private func fullName(_ contact: CNContact) -> String {
        [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func filledFieldCount(_ contact: CNContact) -> Int {
        var count = 0
        if !contact.givenName.isEmpty        { count += 1 }
        if !contact.familyName.isEmpty       { count += 1 }
        if !contact.organizationName.isEmpty { count += 1 }
        if !contact.phoneNumbers.isEmpty     { count += 1 }
        if !contact.emailAddresses.isEmpty   { count += 1 }
        if contact.birthday != nil           { count += 1 }
        if contact.imageDataAvailable        { count += 1 }
        return count
    }

    private func determinePrimary(_ a: CNContact, _ b: CNContact) -> (primary: CNContact, duplicate: CNContact) {
        let countA = filledFieldCount(a)
        let countB = filledFieldCount(b)
        return countA >= countB ? (a, b) : (b, a)
    }
}
