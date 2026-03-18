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
- `Utilities/` — PhoneNormalizer, NameMatcher
- `iOSCleanupTests/` — unit tests for all engines

## Build phases
- **Phase 1** (this branch): headless scan engines + unit tests ✅
- **Phase 2**: results UI, free tier preview
- **Phase 3**: paywall (StoreKit 2), bulk delete/merge

## Running tests
`Cmd+U` in Xcode, or:
```bash
xcodebuild test -scheme iOSCleanup -destination 'platform=iOS Simulator,name=iPhone 15'
```
