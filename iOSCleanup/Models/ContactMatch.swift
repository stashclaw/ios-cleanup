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

    enum MatchReason: Sendable {
        case identicalPhone
        case identicalEmail
        case sameNameDifferentFormat
        case fuzzyName(distance: Int)
    }
}
