# iOSCleanup — Claude Code memory

## What this is
iOS app: phone storage cleaner. On-device only, no server, no third-party SDKs.

## Phase 1 scope
Three headless scan engines only. No production UI.
- PhotoScanEngine: Vision framework VNFeaturePrintObservation, union-find clustering
- ContactScanEngine: CNContactStore, phone normalization, Levenshtein name match
- FileScanEngine: FileManager + PHAsset video enumeration

## Key constraints
- Swift strict concurrency — all engines are actors
- iOS 16.0 minimum
- No external packages (no SPM dependencies)
- Unit tests live in iOSCleanupTests target

## Architecture rules
- Engines are actors, models are Sendable structs
- Use async/await throughout — no completion handlers
- PHImageManager and CNContactStore callbacks must be bridged with withCheckedContinuation
- Never import UIKit in engine files (keep testable without a host app)

## Phase 2 plan (not yet built)
Results UI, free tier preview, paywall (StoreKit 2)
