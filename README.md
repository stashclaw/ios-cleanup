# iOS Cleanup

A phone storage cleaner for iOS. Finds similar photos, duplicate contacts,
and large files — all on-device using Vision, Core ML, and CNContactStore.
No server. No third-party SDKs.

## Requirements
- Xcode 15+
- iOS 16.0+ deployment target
- Swift 5.9

## Getting started
1. Clone the repo
2. Open `iOSCleanup.xcodeproj` in Xcode
3. Select your team in Signing & Capabilities
4. Run on a real device for photo/contact scan (simulator has no library)

## Project structure
- `Engines/` — scan actors (Photo, Contact, File)
- `Models/` — result types (PhotoGroup, ContactMatch, LargeFile)
- `Utilities/` — PhoneNormalizer, NameMatcher, PHAsset+FileSize
- `Views/` — SwiftUI screens and components
- `iOSCleanupTests/` — unit tests for all engines

## File size estimation

All reclaimable-bytes estimates use `PHAsset.estimatedFileSize` (defined in
`Utilities/PHAsset+FileSize.swift`). This reads the actual byte count from
`PHAssetResource` metadata — a synchronous, zero-I/O call — and falls back to a
compression-adjusted pixel estimate (~8:1 ratio) for iCloud-only assets whose
resource records have not synced locally.

**Do not** use `pixelWidth × pixelHeight × 3` (raw uncompressed) anywhere in the
codebase; it overstates real HEIC/JPEG file sizes by 3–5× and erodes user trust.

## Review flow behaviour

- **Review Later** (group list): moves the group to the end of the visible list
  within the current session. Order is not persisted to disk. A "Moved to end of
  list" toast confirms the action.
- **Undo bar**: remains visible for **10 seconds** after a trash action before
  auto-committing. The commit window in `DeletionManager` matches this duration.
- **Move to Trash** (group detail): requires a Pro purchase. A lock icon is shown
  in the button label before the user taps, via `ActionBar(trashIsPaid:)`.

## Accessibility

- Hero card announces state via `.accessibilityValue` so VoiceOver users hear
  status changes that are otherwise communicated only by colour.
- Swipe direction indicators in Duck Mode are marked `.accessibilityHidden(true)`;
  the "Duck it" / "Keep it" buttons below serve as the accessible equivalent.
- Group cards in the results list use a combined `.accessibilityLabel` describing
  reason, confidence, photo count, and reclaimable bytes.
- The kebab menu (…) in group detail carries `.accessibilityLabel("More options")`.

## Build phases
- **Phase 1**: headless scan engines + unit tests ✅
- **Phase 2**: results UI, review flows, Duck Mode, free tier preview ✅
- **Phase 3**: paywall (StoreKit 2), bulk delete/merge ✅

## Running tests
`Cmd+U` in Xcode, or:
```bash
xcodebuild test -scheme iOSCleanup -destination 'platform=iOS Simulator,name=iPhone 15'
```
