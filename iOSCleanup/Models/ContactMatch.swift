import Contacts

struct ContactMatch: Identifiable, @unchecked Sendable {
    let id: UUID
    let primary: CNContact
    let duplicate: CNContact
    let confidence: MatchConfidence
    let reasons: [MatchReason]

    enum MatchConfidence: Sendable {
        case certain
        case probable
        case possible
    }

    var displayTitle: String {
        let name = [primary.givenName, primary.familyName]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? primary.organizationName : name
    }

    var confidenceLabel: String {
        switch confidence {
        case .certain:  return "Exact match"
        case .probable: return "Likely duplicate"
        case .possible: return "Possible duplicate"
        }
    }

    enum MatchReason: Sendable {
        case identicalPhone
        case identicalEmail
        case sameNameDifferentFormat
        case fuzzyName(distance: Int)
    }
}
