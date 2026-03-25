import Photos

struct SemanticGroup: Identifiable, Sendable {
    let id: UUID
    let category: SemanticCategory
    let assets: [PHAsset]
}

enum SemanticCategory: String, CaseIterable, Sendable {
    case foodAndDrink       = "Food & Drink"
    case petsAndAnimals     = "Pets & Animals"
    case natureOutdoors     = "Nature & Outdoors"
    case documentsReceipts  = "Documents & Receipts"
    case architecture       = "Architecture"
    case vehicles           = "Vehicles"

    var icon: String {
        switch self {
        case .foodAndDrink:      return "fork.knife"
        case .petsAndAnimals:    return "pawprint.fill"
        case .natureOutdoors:    return "leaf.fill"
        case .documentsReceipts: return "doc.text.fill"
        case .architecture:      return "building.2.fill"
        case .vehicles:          return "car.fill"
        }
    }

    /// VNClassifyImageRequest identifier prefixes that map to this category.
    var classifierIdentifiers: [String] {
        switch self {
        case .foodAndDrink:
            return ["food", "drink", "meal", "snack", "fruit", "vegetable", "bakery", "restaurant"]
        case .petsAndAnimals:
            return ["animal", "dog", "cat", "bird", "pet", "wildlife", "insect", "fish"]
        case .natureOutdoors:
            return ["outdoor", "nature", "sky", "water", "mountain", "forest", "beach", "plant", "flower", "landscape"]
        case .documentsReceipts:
            return ["text", "document", "receipt", "paper", "book", "label"]
        case .architecture:
            return ["architecture", "building", "interior", "church", "bridge", "cityscape"]
        case .vehicles:
            return ["vehicle", "car", "motorcycle", "bicycle", "airplane", "boat", "train"]
        }
    }
}
