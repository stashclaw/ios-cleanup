# iOS Cleanup

A phone storage cleaner for iOS. Finds similar photos and duplicate shots
on-device using Vision.
No server. No third-party SDKs.

## Requirements
- Xcode 15+
- iOS 16.0+ deployment target
- Swift 5.9

## Getting started
1. Clone the repo
2. Open `iOSCleanup.xcodeproj` in Xcode
3. Select your team in Signing & Capabilities
4. Run on a real device for photo scan (simulator has no library)

## Project structure
- `Engines/` — photo scan actor
- `Models/` — photo result types
- `Utilities/` — brand fonts and UI helpers
- `iOSCleanupTests/` — unit tests for the photo engine

## Build phases
- **Phase 1** (this branch): photo scan engine + unit tests ✅
- **Phase 2**: results UI, paywall, bulk delete
- **Phase 3**: refinements and settings

## Running tests
`Cmd+U` in Xcode, or:
```bash
xcodebuild test -scheme iOSCleanup -destination 'platform=iOS Simulator,name=iPhone 15'
```
