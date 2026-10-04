# Chapter 01 — Foundation: repo, upload blockers, test seams and stop-ship P0s

> **Milestone(s):** M0 · **Workstreams:** WS-01 – WS-05 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

These five workstreams are the floor everything else stands on. WS-01 makes git the single source of truth: today the tested export work is uncommitted, `main` is 8 ahead and 29 behind a divergent prototype `origin/main`, and a stale copy of the app sits in the parent directory. WS-02 clears the two App Store upload blockers: missing required-reason entries in the privacy manifest, and a universal target with a portrait-only iPad. WS-03 puts `DeletionManager`, the only photo-deletion gateway, behind a PhotoKit seam, stops unit tests from booting the full app or writing into the real ML store, and consolidates test doubles. WS-04 and WS-05 fix the three live data-loss bugs: group-detail Keep Best deletes photos the grid shows as "Kept", Duck Mode shows the wrong photo on every card after the first, and an export resume can splice two different files that Export & Delete then treats as verified. When the chapter lands, a user never loses a photo they were shown as kept, never decides on a photo they didn't see, and never has an original deleted without a byte-for-byte hash-verified copy. **Key risk:** WS-05 rewrites the export writer inside a 1,855-line file. Its task order and tests are designed so every step is independently green; do not batch them.

---

## WS-01 — Repo consolidation and WIP commit

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M0 | S | — | no | `feat/ml-training-pipeline`, then local `main` (no `ws/` branch; see WS-01.4) |

**Primary files:** `.gitignore`, `iOSCleanup.xcodeproj/Duck Assets.png` (delete), `tmp/brand-assets/` (retire), `Design/brand/` *new*, `CLAUDE.md`, `spec/` (first commit)
**Findings covered:** BUILD-05 (P1, confirmed; merged: FSA-14)
**Decisions applied:** D-GIT — commit the WIP, fast-forward `main` to the active line, preserve the prototype under an `archive/` tag and branch, supersede it with `merge -s ours` (never a force-push). Every push, every remote-ref change, deleting `phase-2`, and any change to the outer `/Users/justinwong/iOSCLEANER` repo waits for the owner's explicit "yes" in chat.

### Goal
`/Users/justinwong/iOSCLEANER/ios-cleanup` has a clean working tree. Local `main` contains the tested export WIP and this spec. The March prototype line is preserved under `archive/prototype-main-2026-03-27`. Once the owner approves the pushes, GitHub's default branch builds the app described in `ios-cleanup/CLAUDE.md`, and only one checkout of the app exists on disk. Every later workstream branches from this `main`.

### Current behavior (verified)
- Nested repo `git status`: on `feat/ml-training-pipeline` at `519e325`, tracking `origin/feat/ml-training-pipeline`. Three tracked files are modified: `iOSCleanup/Engines/ExternalPhotoExportService.swift` (+399/−170), `iOSCleanup/Views/HomeView.swift` (±50) and `iOSCleanupTests/FileScanEngineTests.swift` (+184), 625 insertions in total. `spec/` is untracked, and this spec lives there. `CLAUDE.md` is also modified: the spec added an "Implementation plan (read first)" pointer section to it.
- Local `main` is `80e539d`, `[origin/main: ahead 8, behind 29]`. `git merge-base --is-ancestor main feat/ml-training-pipeline` is true (feat is 9 commits ahead). `phase-2` (`cc21345`) is also an ancestor of feat. feat is 17 ahead and 29 behind `origin/main` (`ae632ed`, 2026-03-27). The merge base with `origin/main` is `aa3525f`.
- `git log feat/ml-training-pipeline..origin/main --oneline` lists 29 prototype commits (Contacts, Smart Picks, MLModelUpdater, "Add SQLite analysis cache…"). None of them are wanted; the active line re-implemented or removed those features.
- Outer repo `/Users/justinwong/iOSCLEANER`: `.git` has one branch, `main` at `aa3525f`, with no stash and the same `origin` (`https://github.com/stashclaw/ios-cleanup`). It has an uncommitted `CLAUDE.md` edit (now the workspace pointer), untracked `ios-cleanup/`, and a stale contacts-era app in `iOSCleanup/`, `iOSCleanup.xcodeproj/`, `iOSCleanupTests/`, `README.md` and `.gitignore`. `.claude/settings.local.json` is local config and stays. `git -C ios-cleanup merge-base --is-ancestor aa3525f main` is true, so the outer repo holds nothing unique.
- `iOSCleanup.xcodeproj/Duck Assets.png` is tracked (2,278,121 bytes, from web-upload commit `53015e1`), and `project.pbxproj` does not reference it.
- `tmp/brand-assets/` is ignored by `.gitignore` (`tmp/`) and holds 8 PNGs. By md5, 7 are byte-identical to images already in `iOSCleanup/Assets.xcassets`; `photoduck_mascot-source.png` equals `photoduck_icon.imageset/photoduck_icon.png`. Only `photoduck_wordmark-source.png` (1,148,756 bytes) exists nowhere else.
- `Assets/` is an empty, untracked directory.
- `.gitignore` (28 lines) has no entries for `*.xcresult`, SQLite files, `MLTraining/trained-models/`, `PhotoDuck-ML-Export/` or `.claude/settings.local.json`.
- Commit `519e325` mixed an export refactor with a deletion-semantics change (`keepBest` switched from the undo window to an immediate delete). One concern per commit is not written down anywhere.

### Implementation plan

**WS-01.1 — Baseline, then commit the WIP and the spec (on `feat/ml-training-pipeline`)**
- **Why:** Losing the laptop loses the uncommitted export migration and progress UI. Nothing later can branch from a tree with WIP in it.
- **Change:**
  1. `cd /Users/justinwong/iOSCLEANER/ios-cleanup && git fetch origin --prune && git switch feat/ml-training-pipeline`.
  2. Run the full suite (README §4). The expected result is 256 passed, 1 skipped (`testPinnedVisionFeaturePrintScaleUsingDeterministicFixtures` skips in the simulator). If anything else fails, stop and report; do not commit.
  3. `git add iOSCleanup/Engines/ExternalPhotoExportService.swift iOSCleanup/Views/HomeView.swift iOSCleanupTests/FileScanEngineTests.swift && git commit -m "feat(export): migrate legacy per-run export folders; byte-level progress and speed"`. Commit the WIP exactly as it is. Its safety defects (FILES-12, FILES-14) are fixed in WS-05 before any release build; say so in the commit body.
  4. `git add spec CLAUDE.md && git commit -m "docs(spec): add v1 implementation spec"`. `CLAUDE.md` carries an uncommitted "Implementation plan (read first)" section that was added together with this spec; it belongs in this commit. Check with `git diff CLAUDE.md` first: that section should be the only change.
- **Edge cases:** If `git fetch` shows `origin/feat/ml-training-pipeline` moved past `519e325`, stop and report; someone else pushed.

**WS-01.2 — Hygiene commit**
- **Why:** A 2.2 MB stray PNG sits inside the project bundle, the only unique brand source is in an ignored folder, and generated artifacts can be committed by accident.
- **Change (one commit, `chore: repo hygiene`):**
  1. `git rm "iOSCleanup.xcodeproj/Duck Assets.png"`.
  2. `mkdir -p Design/brand && cp tmp/brand-assets/photoduck_wordmark-source.png tmp/brand-assets/photoduck_mascot-source.png Design/brand/`, then `git add Design/brand`. Add `Design/brand/README.md` with one line per file: what it is, and that `photoduck_mascot-source.png` is the source of `photoduck_icon`.
  3. Before deleting `tmp/`, re-run the md5 comparison: every file in `tmp/brand-assets/` must now be byte-identical to a file in `Design/brand/` or `iOSCleanup/Assets.xcassets/`. Only then `rm -rf tmp` (it is untracked and ignored). Also `rmdir Assets`.
  4. Append to `.gitignore` under a `# Local artifacts` heading: `*.xcresult`, `build/TestResults*`, `MLTraining/trained-models/`, `**/PhotoDuck-ML-Export/`, `*.sqlite`, `*.sqlite-wal`, `*.sqlite-shm`, `.claude/settings.local.json`. `git ls-files | grep -E '\.sqlite|xcresult'` must print nothing before and after.
- **Edge cases:** Keep `tmp/` in `.gitignore`, since design tooling may recreate it.

**WS-01.3 — Write the git workflow down**
- **Why:** Failure scenarios (a) through (c) in BUILD-05 are process failures: a force-push of `main`, `git add -A` in the parent directory, or editing the stale copy.
- **Change:** Add a `## Git workflow` section to `ios-cleanup/CLAUDE.md` (≤ 12 lines). It says: this nested repo is the app, and the parent directory is not a repository of the app. `main` is the only long-lived branch. Work happens on `ws/NN-slug` branches cut from `main`, one concern per commit. Never force-push `main`. The March prototype is archived at `archive/prototype-main-2026-03-27`. Pushing and merging need the owner's approval. Commit this in the hygiene commit or on its own.

**WS-01.4 — Move local `main` onto the active line without a force-push (owner-approved step)**
- **Why:** A plain `git push origin main` is rejected as non-fast-forward, and a force-push would destroy 29 archived commits.
- **Change:** Print the block below in your report and run it **only after the owner approves in chat**. It only changes local refs until the final push lines, which need the same approval.
  ```bash
  cd /Users/justinwong/iOSCLEANER/ios-cleanup
  git log feat/ml-training-pipeline..origin/main --oneline > /tmp/ws01-prototype-commits.txt   # paste into the report
  git tag -a archive/prototype-main-2026-03-27 origin/main -m "March prototype line, superseded by the PhotoDuck active line"
  git switch main
  git merge --ff-only feat/ml-training-pipeline
  git merge -s ours --no-ff origin/main -m "chore: supersede March prototype line (archived at archive/prototype-main-2026-03-27)" \
            -m "$(cat /tmp/ws01-prototype-commits.txt)"
  git diff feat/ml-training-pipeline main --stat     # must print nothing
  # --- pushes: owner approval required ---
  git push origin refs/tags/archive/prototype-main-2026-03-27
  git push origin refs/remotes/origin/main:refs/heads/archive/prototype-main-2026-03-27
  git push origin feat/ml-training-pipeline
  git push origin main                                # fast-forward of origin/main; no --force
  ```
  After `main` is pushed, prepare (and run only on approval) `git branch -d phase-2 && git push origin --delete phase-2`, and later `git branch -d feat/ml-training-pipeline && git push origin --delete feat/ml-training-pipeline`.
- **Edge cases:** Do not cherry-pick anything from the 29 prototype commits (contacts-era code violates the current product scope). If `merge --ff-only` fails, stop: local `main` gained commits that were not expected.

**WS-01.5 — Retire the outer repository (owner-approved step, prepare only)**
- **Why:** Failure scenarios (b) and (c): a `git pull` or `git add -A && git push` in the parent directory, or an agent editing `/Users/justinwong/iOSCLEANER/iOSCleanup/*.swift` thinking it is the app.
- **Change:** Print these commands in the report; do not run them without approval.
  ```bash
  git -C /Users/justinwong/iOSCLEANER/ios-cleanup merge-base --is-ancestor aa3525f main && echo "outer repo has nothing unique"
  mv /Users/justinwong/iOSCLEANER/.git /Users/justinwong/iOSCLEANER-outer-git-backup
  # after a second explicit confirmation:
  rm -rf /Users/justinwong/iOSCLEANER/iOSCleanup /Users/justinwong/iOSCLEANER/iOSCleanup.xcodeproj \
         /Users/justinwong/iOSCLEANER/iOSCleanupTests /Users/justinwong/iOSCLEANER/README.md /Users/justinwong/iOSCLEANER/.gitignore
  ```
  Keep `/Users/justinwong/iOSCLEANER/CLAUDE.md` (the non-git pointer) and `/Users/justinwong/iOSCLEANER/.claude/`. GitHub branch protection on `main` (no force-push; require the CI check that WS-06 adds) is an owner action; list it as a follow-up.

### Tests
There are no code tests; this is repository process. Verification commands, with output pasted into the report:
- `git -C /Users/justinwong/iOSCLEANER/ios-cleanup status --short` prints nothing.
- The full suite passed before the WIP commit (256 passed, 1 skipped).
- After WS-01.4: `git rev-parse main` equals the merge commit; `git diff feat/ml-training-pipeline main --stat` is empty; `git merge-base --is-ancestor origin/main main` is true.
- After the approved pushes: `git ls-remote origin archive/prototype-main-2026-03-27` resolves (tag and branch), and `git log origin/main -1` is the merge commit.
- After WS-01.5: `git -C /Users/justinwong/iOSCLEANER rev-parse --git-dir` fails.

### Acceptance criteria
- [ ] The WIP and `spec/` are committed on `feat/ml-training-pipeline`, and the suite was green (256/1 skipped) before the WIP commit.
- [ ] `iOSCleanup.xcodeproj/Duck Assets.png` is removed from git. `Design/brand/` holds the unique brand sources. `tmp/` and `Assets/` are gone. `.gitignore` has the new entries.
- [ ] `ios-cleanup/CLAUDE.md` has the Git workflow section.
- [ ] Local `main` equals the active line plus a `-s ours` merge of `origin/main`. No command used `--force`.
- [ ] Pushes, archive refs, the `phase-2` deletion and the outer-repo retirement were either approved and verified, or are listed as pending owner actions with exact commands.

### Pitfalls and out of scope
- Never `git push --force` and never `git reset --hard origin/main`. The owner approves every push.
- Do not edit anything under `/Users/justinwong/iOSCLEANER/iOSCleanup/`; it is the stale copy.
- Rewriting the contacts-era `ios-cleanup/README.md` belongs to WS-58 (chapter 12); WS-07 (chapter 02) adds the simulator fixture instructions. The CI check for branch protection comes from WS-06 (chapter 02).

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| BUILD-05 | confirmed | Every count was re-derived: ahead 8/behind 29, 9-commit fast-forward, `phase-2` merged, outer `main` at `aa3525f`, PNG tracked and unreferenced. Only nuance: of the "untracked brand sources", only `photoduck_wordmark-source.png` is unique. Added: commit `spec/` (untracked today), and make every push or deletion an owner-approved step per D-GIT. |
| FSA-14 (merged) | confirmed | Same facts. Its README rewrite is deferred to WS-58, and its "force-update main" alternative is rejected by D-GIT. |

---

## WS-02 — App Store upload blockers

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M0 | S | WS-01 | no | `ws/02-upload-blockers` |

**Primary files:** `iOSCleanup/PrivacyInfo.xcprivacy`, `iOSCleanup/Utilities/PhotoDuckDiagnosticClock.swift` *new*, `iOSCleanup/Utilities/SharedHelpers.swift`, `iOSCleanup/Views/HomeViewModel.swift` (one line in `makeDiagnosticReport`), `iOSCleanup/iOSCleanupApp.swift`, `iOSCleanup/Info.plist`, `iOSCleanup.xcodeproj/project.pbxproj`, `iOSCleanupTests/PrivacyManifestLintTests.swift` *new*, `iOSCleanupTests/AppConfigurationTests.swift` *new*, `iOSCleanupTests/FileScanEngineTests.swift` (diagnostics tests), `CLAUDE.md`
**Findings covered:** STORE-01 (P0, confirmed; merged: ML-01, BUILD-01, FSA-01), STORE-02 (P2, confirmed), STORE-04 (P0, confirmed; merged: UI-03, BUILD-06)
**Decisions applied:**
- D-DIAG-UPTIME — diagnostics record seconds since this launch, never device uptime. Keep the SystemBootTime `35F9.1` declaration, bump the report envelope to schema v2, rename the ring file to `events-v2.jsonl` and delete the v1 file.
- D-IPAD — iPhone-only for v1: `TARGETED_DEVICE_FAMILY = 1` on the app, widget and test targets, and no `~ipad` orientation key.

### Goal
A Release archive passes Organizer "Validate App" with no ITMS-91053 (missing API declaration) and no ITMS-90474 (iPad multitasking orientations), so TestFlight builds can feed real-device QA. The privacy manifest is truthful: only elapsed-in-app time leaves the device. A lint test fails if a future change adds a required-reason API without declaring it.

### Current behavior (verified)
- `iOSCleanup/PrivacyInfo.xcprivacy:11-30` declares only `NSPrivacyAccessedAPICategoryUserDefaults` (`CA92.1`) and `NSPrivacyAccessedAPICategoryDiskSpace` (`E174.1`, `85F4.1`).
- **SystemBootTime use:** `iOSCleanup/Utilities/SharedHelpers.swift:682` sets `processUptime = ProcessInfo.processInfo.systemUptime` in `PhotoDuckDiagnosticEvent`'s private init. `iOSCleanup/Views/HomeViewModel.swift:2439` has `let diagnosticUptimeCutoff = ProcessInfo.processInfo.systemUptime`, passed as `currentSessionUptimeCutoff` at `:2444`.
- **FileTimestamp use:** `SharedHelpers.swift:1186-1216` `performStartupMaintenance` enumerates the export directory with `.contentModificationDateKey, .creationDateKey` and compares `values.contentModificationDate ?? values.creationDate` to a cutoff. It runs on every launch from `iOSCleanupApp.swift:36-37`.
- Every other `attributesOfItem`/`resourceValues` call reads only `.size`, `.fileSizeKey`, `.isRegularFileKey`, `.isDirectoryKey` or volume capacity. That includes the user-picked export folder (`ExternalPhotoExportService.swift:1262, 1274, 1345`). No timestamps are read from user-granted files, so `3B52.1` is **not** needed. DiskSpace is already declared (`VideoCompressionEngine.swift:236-244`, `HomeViewModel.swift:569-570`).
- **STORE-02:** `PhotoDuckDiagnosticStoredEvent` (`SharedHelpers.swift:1018-1025`) persists `processUptime`. `exportReport` (`:1122-1184`) encodes every event with ISO8601 `timestamp` plus `processUptime` into the shared JSON, so boot time = timestamp − uptime. It also filters current-session events with `$0.processUptime <= currentSessionUptimeCutoff` (`:1141-1146`). `sortEvents` (`:1295-1305`) uses `processUptime` as a tiebreak. The envelope has `schemaVersion = 1` (`:1028`), and `privacyNotice` (`:1029-1033`) says "states, counts, timings". The ring file is `…/PhotoDuck/Diagnostics/events-v1.jsonl` (`:1088`).
- Existing tests: `FileScanEngineTests.swift:2190-2244` `testDiagnosticExportUsesCurrentSessionUptimeCutoff` uses `ProcessInfo.processInfo.systemUptime` as the cutoff. `:2246-2297` `testDiagnosticStartupMaintenanceRemovesOnlyStaleExports` sets file modification dates.
- **STORE-04:** `project.pbxproj` has `TARGETED_DEVICE_FAMILY = "1,2";` at `:783` and `:804` (app Debug/Release), `:820` and `:837` (tests), and `:862` and `:883` (widget). `iOSCleanup/Info.plist:45-48` has `UISupportedInterfaceOrientations~ipad` = `[UIInterfaceOrientationPortrait]`, and there is no `UIRequiresFullScreen`. No view uses `horizontalSizeClass` or `userInterfaceIdiom`.
- The widget (`PhotoDuckWidgets/*.swift` plus the shared `iOSCleanup/Models/ExportActivityAttributes.swift`) uses no required-reason API, and `PhotoDuckWidgets/PrivacyInfo.xcprivacy` correctly declares none.
- `iOSCleanupTests/DesignLintTests.swift:70-98` shows the `#filePath` source-walk pattern to copy.

### Implementation plan

**WS-02.1 — Session-elapsed diagnostics clock (STORE-02, D-DIAG-UPTIME)**
- **Why:** A shared diagnostics JSON must not let anyone compute device boot time. It must also be true before the manifest declares `35F9.1`.
- **Change:**
  - New file `iOSCleanup/Utilities/PhotoDuckDiagnosticClock.swift`:
    ```swift
    import Foundation

    /// Seconds since this app launch. The only boot-time-derived value PhotoDuck
    /// keeps, and it is always relative (PrivacyInfo reason 35F9.1).
    enum PhotoDuckDiagnosticClock {
        /// Captured once, as early as possible (iOSCleanupApp.init).
        static let launchUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

        static func elapsed(
            uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) -> TimeInterval {
            max(0, uptime - launchUptime)
        }
    }
    ```
  - `iOSCleanupApp.init()` (`iOSCleanupApp.swift:12`): the first statement is `_ = PhotoDuckDiagnosticClock.launchUptime`.
  - `SharedHelpers.swift`: rename `processUptime` to `sessionElapsedSeconds` in `PhotoDuckDiagnosticEvent` (set from `PhotoDuckDiagnosticClock.elapsed()`), in `PhotoDuckDiagnosticStoredEvent`, in `record(_:)`, in `sortEvents()` and in the `exportReport` filter. Rename the parameter `currentSessionUptimeCutoff` to `currentSessionElapsedCutoff`, and update the comment above the filter. Store the value **unrounded**, because the cutoff test relies on sub-millisecond ordering and relative time carries no fingerprint.
  - Set `PhotoDuckDiagnosticReportEnvelope.schemaVersion = 2`, and change `privacyNotice` to: "Contains PhotoDuck states, counts, timings measured from when PhotoDuck was opened, and sanitized error codes. Contains no photos, thumbnails, asset identifiers, filenames, paths, media dates, locations, or device uptime. Diagnostic history is bounded, so older events may be omitted."
  - Change the default ring path to `events-v2.jsonl`. In `performStartupMaintenance`, first remove `fileURL.deletingLastPathComponent().appendingPathComponent("events-v1.jsonl")` when it exists and differs from `fileURL`, then do the existing stale-export sweep unchanged.
  - `HomeViewModel.makeDiagnosticReport` (`:2439-2445`): replace the line with `let diagnosticElapsedCutoff = PhotoDuckDiagnosticClock.elapsed()` and pass `currentSessionElapsedCutoff:`. Change nothing else in HomeViewModel; WS-15 later moves this code into `ScanDiagnosticsRecorder`, and keeping the clock in its own type keeps that move mechanical.
- **Edge cases:** v1 lines never load, because the file is renamed and deleted, and a v1 line would fail to decode anyway. Events from earlier sessions keep their own session-relative values; the export filter applies the cutoff to the current `sessionID` only, as today.

**WS-02.2 — Declare the missing required-reason categories (STORE-01)**
- **Why:** An upload fails with ITMS-91053 for SystemBootTime and FileTimestamp.
- **Change:** Add two dictionaries to `NSPrivacyAccessedAPITypes` in `iOSCleanup/PrivacyInfo.xcprivacy`, keeping the existing two: `NSPrivacyAccessedAPICategorySystemBootTime` with reasons `[35F9.1]`, and `NSPrivacyAccessedAPICategoryFileTimestamp` with `[C617.1]` (diagnostics exports in the app's tmp directory). Leave `PhotoDuckWidgets/PrivacyInfo.xcprivacy` unchanged. Do **not** add `3B52.1`; add it in the same PR only if code starts reading timestamps of files in the user-picked export folder (WS-05 deliberately avoids that).
- **Edge cases:** Keep the file a valid XML plist (`plutil -lint iOSCleanup/PrivacyInfo.xcprivacy`).

**WS-02.3 — iPhone-only target (STORE-04, D-IPAD)**
- **Why:** A universal binary with a portrait-only iPad and no `UIRequiresFullScreen` fails ITMS-90474, and it would expose an untested iPad UI to App Review.
- **Change:** In `project.pbxproj`, set `TARGETED_DEVICE_FAMILY = 1;` in all six build configurations (lines 783, 804, 820, 837, 862, 883). In `iOSCleanup/Info.plist`, delete the `UISupportedInterfaceOrientations~ipad` key and its array (lines 45-48). Keep `UISupportedInterfaceOrientations` = `[UIInterfaceOrientationPortrait]`.
- **Edge cases:** The app still installs on iPad in iPhone compatibility mode. Leave the iPad icon sizes in `AppIcon.appiconset` alone; WS-58 trims the asset catalog.

**WS-02.4 — Lint and configuration tests, plus the pbxproj recipe for this chapter**
- **Why:** The upload blockers are invisible in the simulator and in Debug builds, so tests must pin them.
- **Change:** Add `iOSCleanupTests/PrivacyManifestLintTests.swift` and `iOSCleanupTests/AppConfigurationTests.swift` (see Tests).
- **pbxproj recipe (applies to every new file in this chapter):**
  - Each new Swift file needs:
    - a `PBXFileReference` line (`lastKnownFileType = sourcecode.swift; path = Name.swift; sourceTree = "<group>";`);
    - its ID in the owning `PBXGroup`'s `children`. The groups are app root `AA0000010000000000000601`, Engines `…0604`, Utilities `…0606`, Views/Photos `AA000006000000000000003A`, and tests `AA0000010000000000000602`;
    - a `PBXBuildFile` line;
    - that build-file ID in the right Sources phase: app `AA0000010000000000000901`, tests `AA0000010000000000000902`.
  - IDs must be 24 uppercase hex characters and unique. This chapter uses `D0` + the two-digit workstream number + 16 zeros + a 4-digit counter, for example `D00200000000000000000001`. `grep` the pbxproj to confirm an ID is unused before adding it.
  - A new sub-folder such as `iOSCleanupTests/Support/` needs a `PBXGroup` with `path = Support;`, listed in its parent group's children.
  - Validate with `xcodebuild -project iOSCleanup.xcodeproj -list` and a build.

### Tests
All tests are hosted unit tests and run in the simulator.
- `iOSCleanupTests/PrivacyManifestLintTests.swift` (`final class PrivacyManifestLintTests: XCTestCase`). The repo root is `URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()`; throw `XCTSkip` if sources are absent, like DesignLintTests.
  - `rules: [(category: String, patterns: [String])]` as `NSRegularExpression` patterns:
    - SystemBootTime: `\bsystemUptime\b`, `\bmach_absolute_time\b`
    - FileTimestamp: `\bcontentModificationDateKey\b`, `\bcreationDateKey\b`, `\bcontentAccessDateKey\b`, `\battributeModificationDateKey\b`, `\bfileModificationDate\b`, `FileAttributeKey\.(creationDate|modificationDate)`, `\[\s*\.(creationDate|modificationDate)\s*\]`, `\bgetattrlist`, `\b[lf]?stat\(`
    - DiskSpace: `\bvolumeAvailableCapacity`, `\bvolumeTotalCapacity`, `\bsystemFreeSize\b`, `\bsystemSize\b`, `\bstatv?fs\(`
    - UserDefaults: `\bUserDefaults\b`, `@AppStorage\b`
    - ActiveKeyboards: `\bactiveInputModes\b`
  - Skip lines whose trimmed text starts with `//`. Report offenders as `File.swift:line`.
  - `knownReasons`:
    - SystemBootTime `{35F9.1, 8FFB.1, 3D61.1}`
    - FileTimestamp `{DDA9.1, C617.1, 3B52.1, 0A2A.1}`
    - DiskSpace `{85F4.1, E174.1, 7D9E.1, B728.1}`
    - UserDefaults `{CA92.1, 1C8F.1, C56D.1, AC6B.1}`
    - ActiveKeyboards `{3EC4.1, 54BD.1}`
  - The tests:
    - `testAppManifestDeclaresEveryRequiredReasonCategoryUsedInAppSources` walks `iOSCleanup/**/*.swift` against `iOSCleanup/PrivacyInfo.xcprivacy`. It fails on today's code for SystemBootTime and FileTimestamp.
    - `testWidgetManifestDeclaresEveryRequiredReasonCategoryUsedInWidgetSources` covers `PhotoDuckWidgets/**/*.swift` plus `iOSCleanup/Models/ExportActivityAttributes.swift`, against `PhotoDuckWidgets/PrivacyInfo.xcprivacy`.
    - `testManifestsAreValidPlistsWithKnownReasonCodes` loads each file with `PropertyListSerialization`. Every declared category must be a known key with at least one reason, and every reason must be in `knownReasons[category]`.
    - `testAppManifestDeclaresExactlyTheExpectedCategories` checks the set equals {UserDefaults, DiskSpace, FileTimestamp, SystemBootTime}.
- `iOSCleanupTests/AppConfigurationTests.swift` is hosted, so `Bundle.main` is `iOSCleanup.app`. This workstream creates the file; WS-48 (chapter 10) and WS-58 (chapter 12) later **extend** it and never re-create it:
  - `testAppIsIPhoneOnly`: `Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int] == [1]`.
  - `testAppDeclaresNoIPadOrientations`: the `~ipad` key is nil, and `UISupportedInterfaceOrientations == ["UIInterfaceOrientationPortrait"]`.
  - `testWidgetExtensionIsIPhoneOnly`: `Bundle(url: Bundle.main.builtInPlugInsURL!.appendingPathComponent("PhotoDuckWidgets.appex"))` has `UIDeviceFamily == [1]`.
  - `testPrivacyManifestIsBundled`: `Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil`.
- Diagnostics, in `FileScanEngineTests.swift` (WS-03 later moves them to `PhotoDuckDiagnosticLogTests.swift`):
  - Rename `testDiagnosticExportUsesCurrentSessionUptimeCutoff` to `testDiagnosticExportUsesCurrentSessionElapsedCutoff`, using `PhotoDuckDiagnosticClock.elapsed()` as the cutoff. The existing 1 ms sleep stays; WS-06 keeps it as an allowed elapsed-time separation and marks it `// test-sleep-ok:`.
  - New `testDiagnosticExportContainsOnlySessionElapsedTimes`: record two events, export, and parse with `JSONSerialization`. Check that `schemaVersion == 2`, that no event dictionary has a `processUptime` key, that each `sessionElapsedSeconds` is a number `>= 0 && < 86_400`, and that event order is preserved.
  - New `testStartupMaintenanceDeletesLegacyV1EventRing`: temp dir with `events-v1.jsonl` and `fileURL = dir/events-v2.jsonl`. After `performStartupMaintenance()`, v1 is gone and v2 is untouched.
  - New `testDiagnosticClockElapsedIsNonNegativeAndMonotonic`: two successive `elapsed()` values, the second `>=` the first, and both `>= 0`; also `elapsed(uptime: 0) == 0`.
  - `testDiagnosticStartupMaintenanceRemovesOnlyStaleExports` still passes unchanged.

### Acceptance criteria
- [ ] `PrivacyInfo.xcprivacy` declares UserDefaults (`CA92.1`), DiskSpace (`E174.1`, `85F4.1`), FileTimestamp (`C617.1`) and SystemBootTime (`35F9.1`). The widget manifest is unchanged.
- [ ] No `processUptime` identifier remains (`grep -rn processUptime iOSCleanup iOSCleanupTests` is empty), and `systemUptime` appears only in `PhotoDuckDiagnosticClock.swift`.
- [ ] The envelope schema is 2, the ring file is `events-v2.jsonl`, and the v1 file is deleted at launch.
- [ ] All six `TARGETED_DEVICE_FAMILY` values are `1`, and `UISupportedInterfaceOrientations~ipad` is gone.
- [ ] The new lint and configuration tests pass; the manifest lint fails if a `systemUptime` use is added while the SystemBootTime entry is removed (check locally, then revert).
- [ ] The full suite is green with zero new warnings.
- [ ] `ios-cleanup/CLAUDE.md` gains an "App Store configuration" bullet list: iPhone-only, the declared privacy categories with reasons, and "PrivacyManifestLintTests must pass; add a category in the same PR as a new required-reason API".
- [ ] Owner step (needs signing): a Release archive passes Organizer "Validate App", "Generate Privacy Report" lists exactly UserDefaults, DiskSpace, FileTimestamp and SystemBootTime, and a TestFlight upload is accepted. Record the result in the PR.

### Device QA
Add to `docs/DEVICE_QA.md`. WS-09 creates the file; if it does not exist yet, create it with a `## Pending steps from chapter 01` section, which WS-09 folds in rather than overwrites.
1. Archive Release → Organizer → Validate App: no ITMS-91053, ITMS-90474 or ITMS-90473. Generate Privacy Report: the four categories above.
2. Install the TestFlight build on an iPad if one is available: it runs in iPhone compatibility mode, portrait.
3. On the iPhone: Help → Share Diagnostics → Prepare. Open the JSON: `schemaVersion` is 2, events have `sessionElapsedSeconds` and no `processUptime`.

### Pitfalls and out of scope
- Do not move diagnostics out of HomeViewModel here (WS-15, chapter 04). Change only the single cutoff line.
- Do not raise the deployment target (D-MIN-OS is WS-06, chapter 02).
- Versioning from build settings and the asset-catalog cleanup belong to WS-58 (chapter 12).
- The invariant "only elapsed-time values leave the device" now holds. Any future diagnostic field derived from `systemUptime` must go through `PhotoDuckDiagnosticClock`.
- Reconciliation (README §9, contract 17): `AppConfigurationTests.swift` is owned by this workstream. WS-48 and WS-58 add test methods to the same class; they must not create a second file or class with that name.
- Reconciliation: the acceptance grep ("`systemUptime` appears only in `PhotoDuckDiagnosticClock.swift`") is checked when WS-02 lands; it is not a standing lint. Later in-process timers may read `systemUptime` to measure elapsed time under `35F9.1` (WS-50's `progressClock`, WS-53's `refreshClock`), provided the value is never persisted or exported. `PrivacyManifestLintTests` still requires the SystemBootTime declaration.
- Reconciliation: the 1 ms sleep in the renamed cutoff test is not removed by WS-06. WS-06.5 allows it with a `// test-sleep-ok:` marker, and WS-03 moves the test to `PhotoDuckDiagnosticLogTests.swift`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| STORE-01 | confirmed | `systemUptime` at `SharedHelpers.swift:682` and `HomeViewModel.swift:2439`; `contentModificationDateKey`/`creationDateKey` at `SharedHelpers.swift:1193-1194`. The manifest lacks both categories. Kept `performStartupMaintenance`'s age-based sweep (tested) instead of the optional "delete all at launch" reduction; C617.1 covers it. |
| ML-01 (merged) | confirmed | Same evidence. The "ContinuousClock instead" option was not taken; D-DIAG-UPTIME keeps the `35F9.1` declaration with a launch baseline. |
| BUILD-01 (merged) | partially | The categories are real, but `attributesOfItem` is not itself a listed FileTimestamp API, and every call reads `.size` only. The export folder's timestamps are never read, so `3B52.1` is not added. Its lint test design is adopted, with regex word boundaries and comment skipping. |
| FSA-01 (merged) | confirmed | Same evidence; its CLAUDE.md App Store section update is included. |
| STORE-02 | confirmed | `processUptime` is persisted and exported next to ISO8601 timestamps. The fix follows the reviewer, except the value is stored unrounded: 0.1 s rounding would break the strict current-session cutoff, and elapsed time since launch is not a fingerprint. |
| STORE-04 | confirmed | Six `"1,2"` settings and the portrait-only `~ipad` key confirmed. That the upload is actually rejected can only be seen at Organizer validation (owner step). |
| UI-03 (merged) | confirmed | Same fix. |
| BUILD-06 (merged) | confirmed | Its widget `builtInPlugInsURL` test is adopted in `AppConfigurationTests`. |

---

## WS-03 — Test foundation: DeletionManager seam, isolated test host, shared doubles

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M0 | M | WS-01 | no | `ws/03-test-foundation` |

**Primary files:** `iOSCleanup/Engines/PhotoLibraryDeleting.swift` *new*, `iOSCleanup/Engines/DeletionManager.swift`, `iOSCleanup/AppEntry.swift` *new*, `iOSCleanup/iOSCleanupApp.swift`, `iOSCleanupTests/Support/TestPhotoAsset.swift` *new*, `iOSCleanupTests/Support/IsolatedMLStore.swift` *new*, `iOSCleanupTests/DeletionManagerTests.swift` *new*, `iOSCleanupTests/TestIsolationLintTests.swift` *new*, `iOSCleanupTests/ExternalPhotoExportServiceTests.swift` *new*, `iOSCleanupTests/ExportAlbumStoreTests.swift` *new*, `iOSCleanupTests/PhotoDuckDiagnosticLogTests.swift` *new*, `iOSCleanupTests/PhotoImageRepositoryTests.swift` *new*, `iOSCleanupTests/PhotoScanEngineTests.swift`, `iOSCleanupTests/PurchaseManagerTests.swift`, `iOSCleanupTests/FileScanEngineTests.swift`, `iOSCleanupTests/SimilarityPolicyTests.swift`, `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`
**Findings covered:** BUILD-03 (P1, confirmed; merged: DEL-17), BUILD-09 (P2, confirmed), BUILD-19 (P3, confirmed)
**Decisions applied:** none directly. This workstream tests today's immediate deletion paths only; D-UNDO (the retirement of the undo window) is WS-11's job.

### Goal
`DeletionManager` is constructed in unit tests with a recording PhotoKit double, and its keeper exclusion, dedupe, decline handling and stats accounting are pinned by tests. Hosted unit tests run inside an inert host app: no StoreKit listener, no HomeViewModel bootstrap, no scan, no writes to the real ML SQLite store. One shared `TestPhotoAsset` replaces three copies, the test target compiles with zero warnings, and the 2,453-line `FileScanEngineTests` is split by subject.

### Current behavior (verified)
- `iOSCleanup/Engines/DeletionManager.swift:92-97`: `init(cleanupStatsStore:)` is the only seam.
  - `:366-381` `performDelete` calls `PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(...) }` directly.
  - `:395-399` `estimatedBytes` uses `a.estimatedFileSize`, which reads the global `AssetFileSizeCache.shared` (`PHAsset+FileSize.swift:665-675`).
  - Live paths: `keepBest(from:)` at `:105-111`, which calls `keepBestImmediately` at `:115-144` (`validate(groups:)`, then `deleteCandidateAssets`, then a delete, then stats); and `delete(assets:)` at `:146-148`, which calls `deleteImmediately` at `:151-180`.
  - `scheduleDelete` (`:280-364`) has no callers; WS-11 deletes it.
- `PHAssetChangeRequest.deleteAssets` appears only at `DeletionManager.swift:370` and `VideoCompressionEngine.swift:522` (the documented compression exemption).
- `grep DeletionManager iOSCleanupTests/*.swift` finds 0 matches. `CleanupStatsStore` tests live in `PhotoScanEngineTests.swift:1645-1676`.
- `iOSCleanup/iOSCleanupApp.swift:5` is `@main`. `:7-9` create `PurchaseManager`, `DeletionManager` and `ExportAlbumStore` as `@StateObject`s. `:12-15` `init` runs `VideoCompressionEngine.performStartupCleanup()` and installs the notification delegate. The `.task`s at `:26-49` run purchase refresh, file-size warmup, Live Activity cleanup and diagnostics maintenance. `ContentView.swift:5` creates `@StateObject HomeViewModel()`, whose `init` (`HomeViewModel.swift:298-310`) calls `bootstrapLibraryStateIfNeeded()`.
- `project.pbxproj:821,838`: `TEST_HOST` is `iOSCleanup.app`. Nothing in `iOSCleanup/` checks for XCTest.
- `PhotoScanEngine.init` defaults `mlBridge: PhotoMLBridge = .shared` (`PhotoScanEngine.swift:358-361`). Eight tests omit `mlBridge:` (`PhotoScanEngineTests.swift:391, 416, 449, 576, 611, 717, 771, 981`), and `:15` does `_ = PhotoScanEngine()` (construction only). The test at `:635-693` shows the isolated pattern: `PhotoMLBridge(store: PhotoMLStore(directoryURL: tempDirectory))`.
- `PurchaseManagerTests.swift:19-38`: the `@MainActor` class has stored `suiteName`/`defaults` mutated in nonisolated `setUpWithError`/`tearDownWithError`, which produces 7 warnings (lines 27, 28, 29, 35, 36, 37 in the scratch test log).
- There are three private `PHAsset` doubles, and none override `hash`/`isEqual`:
  - `PhotoScanEngineTests.swift:2197` `PhotoScanTestAsset`: id, creationDate, fixed 4032×3024, `.image`; 21 uses.
  - `FileScanEngineTests.swift:2409` `ExternalExportTestAsset`: id only; 12 uses.
  - `SimilarityPolicyTests.swift:781` `TestPhotoAsset`: id only; 9 uses.
- `PHAsset` is `NS_SWIFT_SENDABLE` in the iOS 26.5 SDK, so `[PHAsset]` crosses actors without warnings. `PHAssetResource` is not Sendable.
- `FileScanEngineTests.swift` has 2,453 lines and 66 tests. It covers sizing and video scans, but also the image repository (`:612-770`), export (`:828-1620`), the export album (`:501-524`, `:1621-1677`) and diagnostics (`:1678-2298`).

### Implementation plan

**WS-03.1 — PhotoKit seam for DeletionManager**
- **Why:** Nothing catches a regression that deletes a keeper, records stats after a declined dialog, or double-counts; commit `519e325` changed deletion semantics with all 253 tests green.
- **Change:**
  - New file `iOSCleanup/Engines/PhotoLibraryDeleting.swift`:
    ```swift
    import Photos

    /// The PhotoKit delete call. DeletionManager is its only client (the compression
    /// swap in VideoCompressionEngine is the single documented exemption).
    protocol PhotoLibraryDeleting: Sendable {
        /// Presents the system confirmation. Throws PHPhotosError.userCancelled (3072) when declined.
        func delete(_ assets: [PHAsset]) async throws
    }

    struct SystemPhotoLibraryDeleter: PhotoLibraryDeleting {
        func delete(_ assets: [PHAsset]) async throws {
            guard !assets.isEmpty else { return }
            // Move today's DeletionManager.performDelete continuation here verbatim,
            // including DeletionManagerError.photoLibraryRejectedDeletion on !success.
        }
    }

    typealias PhotoAssetResolver = @Sendable ([String]) async -> [String: PHAsset]
    typealias PhotoAssetByteEstimator = @Sendable (PHAsset) -> Int64

    enum PhotoLibraryDefaults {
        /// Fetches live assets off the main actor. WS-11 calls this at commit time (DEL-06).
        static let resolveAssets: PhotoAssetResolver = { identifiers in
            guard !identifiers.isEmpty else { return [:] }
            return await Task.detached(priority: .userInitiated) {
                let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                var byID: [String: PHAsset] = [:]
                byID.reserveCapacity(result.count)
                result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
                return byID
            }.value
        }
        static let estimateBytes: PhotoAssetByteEstimator = { $0.estimatedFileSize }
    }
    ```
  - `DeletionManager`: the new init is `init(cleanupStatsStore: CleanupStatsStore = CleanupStatsStore(), deleter: any PhotoLibraryDeleting = SystemPhotoLibraryDeleter(), assetResolver: @escaping PhotoAssetResolver = PhotoLibraryDefaults.resolveAssets, byteEstimator: @escaping PhotoAssetByteEstimator = PhotoLibraryDefaults.estimateBytes)`. Store them as `private let`; `assetResolver` is `let` with a doc comment "consumed by WS-11". `performDelete(assets:)` becomes `guard !assets.isEmpty else { return }; try await deleter.delete(assets)`. `estimatedBytes(for:)` sums `byteEstimator($0)`. `iOSCleanupApp` keeps `DeletionManager()` unchanged.
- **Edge cases:** Keep `DeletionManager.isUserCancellation(_:)` as is. Do not touch `scheduleDelete`/undo state (WS-11 deletes it). `PHAssetChangeRequest.deleteAssets` must now appear only in `PhotoLibraryDeleting.swift` and `VideoCompressionEngine.swift`.

**WS-03.2 — Inert unit-test host (BUILD-09)**
- **Why:** On the dev simulator (Photos granted, onboarded), `xcodebuild test` starts a real library scan and StoreKit listener in the host while tests run, and the host app writes to the same SQLite file the tests use.
- **Change:**
  - New file `iOSCleanup/AppEntry.swift`:
    ```swift
    import SwiftUI

    @main
    enum AppEntry {
        static var isRunningUnitTests: Bool {
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        }

        @MainActor
        static func main() {
            #if DEBUG
            if isRunningUnitTests {
                UnitTestHostApp.main()
                return
            }
            #endif
            iOSCleanupApp.main()
        }
    }

    #if DEBUG
    /// Hosted unit tests need a running app but none of PhotoDuck's managers.
    struct UnitTestHostApp: App {
        var body: some Scene { WindowGroup { Text("Unit tests") } }
    }
    #endif
    ```
  - Remove `@main` from `iOSCleanupApp` (`iOSCleanupApp.swift:5`); keep everything else there unchanged. If the compiler rejects `@MainActor static func main()` in the `@main` type, use a `iOSCleanup/main.swift` with the same `if` as top-level code (top-level code is main-actor isolated) and no `@main` anywhere. Record that as a deviation.
- **Edge cases:** WS-07 later hoists `HomeViewModel` into `iOSCleanupApp` as a `@StateObject`; AppEntry keeps the test host inert regardless. UI tests (none today) are unaffected because the variable is set only for hosted unit tests. Release builds compile the `#if DEBUG` branch out.

**WS-03.3 — Isolated ML store for every engine test (BUILD-09)**
- **Why:** Eight engine tests upsert rows for fake IDs (`degraded-0`, `existing`, …) into the developer's real `Application Support/PhotoDuck/ml/photoduck-ml.sqlite`.
- **Change:** New file `iOSCleanupTests/Support/IsolatedMLStore.swift`:
  ```swift
  import XCTest
  @testable import iOSCleanup

  extension XCTestCase {
      /// A PhotoMLBridge on a throwaway SQLite store, deleted at teardown.
      /// Reused by WS-08, WS-20 and WS-23.
      func makeIsolatedMLBridge() -> PhotoMLBridge {
          let directory = FileManager.default.temporaryDirectory
              .appendingPathComponent("PhotoDuckMLTests-\(UUID().uuidString)", isDirectory: true)
          addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
          return PhotoMLBridge(store: PhotoMLStore(directoryURL: directory))
      }
  }
  ```
  Pass `mlBridge: makeIsolatedMLBridge()` in all nine `PhotoScanEngine(` constructions in `PhotoScanEngineTests.swift`, including `:15`. Replace the hand-rolled temp bridge at `:635-642` with the helper.
- **Edge cases:** Other `.shared` singletons reachable from tests (`PhotoFeedbackStore.shared` via `SwipeModeViewModel` and `DeletionManager.undoLast`, `ExternalPhotoExportSessionGate.shared`, `PhotoAnalysisCache.shared`) are listed in the PR as known. Do not refactor them here; WS-07 and WS-11 remove or inject them.

**WS-03.4 — One shared `TestPhotoAsset` (BUILD-19)**
- **Why:** Three copies drift, none has value-based equality, and later workstreams (WS-04, WS-05, WS-08, WS-11, WS-13) need favorites, bursts, media type and `canPerform`.
- **Change:** New file `iOSCleanupTests/Support/TestPhotoAsset.swift`:
  ```swift
  import Photos

  class TestPhotoAsset: PHAsset, @unchecked Sendable {   // not final: WS-08's ConfigurablePhotoScanTestAsset subclasses it
      private let id: String
      private let stub: Stub
      struct Stub {
          var creationDate: Date? = nil, modificationDate: Date? = nil
          var pixelWidth = 0, pixelHeight = 0
          var mediaType: PHAssetMediaType = .unknown, mediaSubtypes: PHAssetMediaSubtype = []
          var duration: TimeInterval = 0, isFavorite = false, isHidden = false
          var burstIdentifier: String? = nil, representsBurst = false
          var burstSelectionTypes: PHAssetBurstSelectionType = []
          var sourceType: PHAssetSourceType = .typeUserLibrary
          var canPerform = true
      }
      init(localIdentifier: String, _ stub: Stub = Stub()) { id = localIdentifier; self.stub = stub; super.init() }

      /// PhotoScanEngineTests' former defaults: a 12 MP still image.
      static func photo(_ id: String, creationDate: Date) -> TestPhotoAsset {
          TestPhotoAsset(localIdentifier: id, .init(creationDate: creationDate,
              pixelWidth: 4_032, pixelHeight: 3_024, mediaType: .image))
      }

      override var localIdentifier: String { id }
      override var creationDate: Date? { stub.creationDate }
      // …override every Stub field the same way…
      override func canPerform(_ editOperation: PHAssetEditOperation) -> Bool { stub.canPerform }
      // NSObject equality: override the `hash` property (not hash(into:)), see commit 38b17ca.
      override var hash: Int { id.hashValue }
      override func isEqual(_ object: Any?) -> Bool { (object as? PHAsset)?.localIdentifier == id }
  }
  ```
  - The defaults equal a bare `PHAsset()`, so `SimilarityPolicyTests` and the export tests keep their behavior when switched to `TestPhotoAsset(localIdentifier:)`.
  - Replace `PhotoScanTestAsset(localIdentifier: x, creationDate: d)` with `TestPhotoAsset.photo(x, creationDate: d)`.
  - Delete the three private classes.
- **Edge cases:** Keep `PHAsset()` literals used as placeholder sources (`FileScanEngineTests.swift:11, 23, 558`); they are not doubles.

**WS-03.5 — PurchaseManagerTests isolation fix (BUILD-19)**
- **Why:** 7 warnings today, which become errors under WS-06's warnings-as-errors and Swift 6.
- **Change:** Delete lines 22-38 (stored properties and both overrides). Add:
  ```swift
  private lazy var defaults: UserDefaults = makeIsolatedDefaults()

  private func makeIsolatedDefaults() -> UserDefaults {
      let suiteName = "PurchaseManagerTests.\(UUID().uuidString)"
      addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
      return UserDefaults(suiteName: suiteName)!
  }
  ```
  The rest of the file keeps using `defaults`. Each test instance gets a fresh suite.

**WS-03.6 — DeletionManagerTests (BUILD-03)**
- **Why:** This is the safety net for the only deletion gateway; see Tests.
- **Change:** New `iOSCleanupTests/DeletionManagerTests.swift` (`@MainActor final class DeletionManagerTests: XCTestCase`, no stored properties and no `setUp` overrides). Doubles are file-private:
  ```swift
  actor RecordingDeleter: PhotoLibraryDeleting {
      private(set) var calls: [[String]] = []
      private var nextError: Error?
      func failNext(with error: Error) { nextError = error }
      func delete(_ assets: [PHAsset]) async throws {
          calls.append(assets.map(\.localIdentifier))
          if let error = nextError { nextError = nil; throw error }
      }
  }
  ```
  Helpers:
  - `makeManager(deleter:bytes:)` builds `DeletionManager(cleanupStatsStore: CleanupStatsStore(defaults: isolatedDefaults()), deleter: deleter, assetResolver: { _ in [:] }, byteEstimator: { bytes[$0.localIdentifier] ?? 0 })`.
  - `eligibleGroup(keeper:candidates:)` builds `PhotoGroup(assets:similarity: 0.98, reason: .nearDuplicate, groupConfidence: .high, recommendedAction: .keepBestTrashRest, keeperAssetID:deleteCandidateIDs:reclaimableBytes: 0)` from `TestPhotoAsset`s. Passing `reclaimableBytes` avoids the global size cache.
  - Move `testCleanupStatsStorePersistsConfirmedTotalsAndClampsOverflow` and `testCleanupStatsStoreIgnoresNegativeDeltas` here from `PhotoScanEngineTests.swift:1645-1676`.

**WS-03.7 — Split FileScanEngineTests (BUILD-19)**
- **Why:** About 45 of its 66 tests are not about FileScanEngine, and WS-05 needs a real `ExternalPhotoExportServiceTests.swift` to edit.
- **Change:** Move tests by name only; do not edit their bodies. Each new file gets `import XCTest`, `import Photos` and `@testable import iOSCleanup`, plus a pbxproj entry (WS-02.4 recipe), and moves the private helpers it uses.
  - `PhotoImageRepositoryTests.swift`: `testImageRepository*` and `testImageRequest*` (`:612-770`), `imageRequestKey(` (`:2311`), `ImageOperationProbe` (`:2374`).
  - `ExternalPhotoExportServiceTests.swift`: every test from `testExternalExportProgressUsesClampedCurrentFileFraction` (`:828`) through `testExternalExportRejectsDuplicateAssetsBeforeCreatingFiles` (`:1595-1620`), including the single-folder, migration, capacity, naming and write-state tests. Also move the helpers `makeExportTemporaryDirectory`, `writeExportManifest`, `makeManifestEntry`, `makeLegacyExportFolder` and `exportManifestFilename`, with `ExternalExportTestAsset` replaced by `TestPhotoAsset`.
  - `ExportAlbumStoreTests.swift`: `testExportAlbumSelectionReturnsOnlyExplicitUniqueAssets` (`:501`), `testExportAlbumDeduplicatesAndPersistsAssetIdentifiers` and `testExportAlbumRemovalAndClearUseExplicitIdentifiers` (`:1621-1677`).
  - `PhotoDuckDiagnosticLogTests.swift`: every `testDiagnostic*` test (`:1678-2298`) and `diagnosticSnapshot()` (`:2324-2373`).
  - Everything else stays in `FileScanEngineTests.swift`: sizing, video scan, the large-video cache and review models, the file-size repository, authorization and `FileDeletionErrorPolicy`.
- **Edge cases:** The total test count before and after the split must be identical. Record both numbers in the PR.

### Tests
All run in the simulator with no Photos access; none touch the real library.
- `DeletionManagerTests`:
  - `testKeepBestSendsExactlyTheDeleteCandidatesAndNeverTheKeeper`: group K+{A,B,C}; `calls == [["A","B","C"]]` in any order, and `"K"` is never in any call.
  - `testKeepBestRejectsVisuallySimilarGroupWithoutCallingPhotoKit`: a `.visuallySimilar` group built with a keeper and candidates, which `PhotoGroup.init` downgrades. It throws a `PhotoDeletionGuardrailError` and `calls` is empty.
  - `testKeepBestRejectsGroupWithoutKeeper`: `keeperAssetID: nil` throws, and `calls` is empty.
  - `testKeepBestRejectsCrossGroupKeeperConflict`: g1's keeper is a candidate in g2; `keepBest(from: [g1, g2])` throws `.crossGroupKeeperConflict`, and `calls` is empty.
  - `testDeleteSendsEachAssetOnce`: `delete(assets: [a, aDuplicateWithSameID, b])` gives `calls == [["a","b"]]`.
  - `testDeleteRejectsEmptySelection`: throws `.emptyDeleteCandidateList`, and `calls` is empty.
  - `testDeclinedSystemPromptRecordsNothing`: `failNext(NSError(domain: PHPhotosErrorDomain, code: 3072))`. The call rethrows, `DeletionManager.isUserCancellation(error)` is true, `lifetimeBytesFreed`/`lifetimeItemsFreed`/`totalBytesFreed` are unchanged, `lastDeletionError == nil`, and a fresh `CleanupStatsStore` on the same suite loads zeros.
  - `testFailedDeletionRecordsNothing`: a generic `NSError` is rethrown, and stats are unchanged.
  - `testSuccessfulDeletionRecordsEstimatedBytesAndCountOnce`: byte estimates {a: 1_000, b: 2_500}. After `delete(assets:[a,b])`: `lifetimeBytesFreed == 3_500`, `lifetimeItemsFreed == 2`, and the values persist via a new `CleanupStatsStore(defaults:)`.
  - `testPhotoKitDeleteIsCalledOnlyFromTheDeletionSeam`: a source lint (the `#filePath` walk of `iOSCleanup/**/*.swift`). `PHAssetChangeRequest.deleteAssets` may appear only in `PhotoLibraryDeleting.swift` and `VideoCompressionEngine.swift`.
  - The two moved `CleanupStatsStore` tests.
  - Mutation check (manual, before opening the PR): temporarily include the keeper in `keepBestImmediately`, and temporarily record stats before `performDelete`. Both must make a test fail. Note the result in the PR.
- `TestIsolationLintTests`:
  - `testEveryPhotoScanEngineInTestsInjectsAnMLBridge`: walk `iOSCleanupTests/**/*.swift` except this file. For each `PhotoScanEngine(` occurrence, extract the balanced-parenthesis argument text and require that it contains `mlBridge:`. Report `File:line` offenders.
  - `testUnitTestHostDoesNotBootTheApp`: `XCTAssertTrue(AppEntry.isRunningUnitTests)`, and `XCTAssertNil(UNUserNotificationCenter.current().delegate)`. `iOSCleanupApp.init` installs that delegate, so nil proves the real app did not start.
  - `testTestPhotoAssetEqualityFollowsLocalIdentifier`: two instances with the same ID are `isEqual`, have equal `hash`, and dedupe in a `Set<PHAsset>`.
- After the split, the suite passes with an unchanged total plus the new tests, and `xcodebuild build-for-testing` shows no warnings in `PurchaseManagerTests.swift`.

### Acceptance criteria
- [ ] `DeletionManagerTests` has at least 9 passing tests, and the manual mutation check made at least one test fail.
- [ ] `DeletionManager()` in `iOSCleanupApp` is unchanged, and `PHAssetChangeRequest.deleteAssets` exists only in the seam file and `VideoCompressionEngine.swift`.
- [ ] In the test host, `UnitTestHostApp` runs, `UNUserNotificationCenter.current().delegate` is nil, and no `PhotoScanEngine(` in tests lacks `mlBridge:`.
- [ ] `grep -rnE "class [A-Za-z]+: PHAsset" iOSCleanupTests` finds exactly one match, in `Support/TestPhotoAsset.swift`.
- [ ] The test target builds with zero warnings, and the total test count before and after the split is recorded and equal (plus new tests).
- [ ] `ios-cleanup/CLAUDE.md` is updated:
  - The test-coverage line adds "DeletionManager (PhotoLibraryDeleting seam)".
  - A new line says: hosted unit tests run under the inert `UnitTestHostApp`, and engine tests must use `makeIsolatedMLBridge()`.
  - The `DeletionManager` row is left alone; WS-11 rewrites it.

### Pitfalls and out of scope
- Do not change deletion behavior here. Test the **current** immediate paths. Concurrency and in-flight guards (BUILD-03 case g), typed `.declined` results and commit-time resolution are WS-11 (chapter 03).
- Do not grow `PhotoScanEngine.swift`; only the tests change.
- Random test ordering and test plans are WS-06 (chapter 02). Removing `Task.sleep` from tests is WS-06.
- WS-08 (chapter 02) builds `ConfigurablePhotoScanTestAsset` on `TestPhotoAsset`, or uses it directly; keep `Stub` easy to extend.
- Reconciliation: `TestPhotoAsset` is declared non-`final` here, because WS-08.2 subclasses it. WS-08 therefore no longer has to edit this file.
- Reconciliation: the `options: nil` in `PhotoLibraryDefaults.resolveAssets` is today's PhotoKit default and stays for now. WS-40 (chapter 08) later adds `PhotoLibraryFetch.identifierOptions()` (`includeAllBurstAssets = true`) and `PhotoFetchLintTests`, which forbids `options: nil` on every `PHAsset.fetchAssets` call in `iOSCleanup/`. This resolver, or its WS-11 successor, is one of the identifier fetches WS-40 must convert, so hidden burst frames still resolve at commit time.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| BUILD-03 | confirmed | Zero DeletionManager references in tests; `performDelete` and `estimatedBytes` are hard-wired. Case (g) (concurrent deletes) is deferred to WS-11. The protocol shape (`PhotoLibraryDeleting.delete(_:)`) follows BUILD-03, and the resolver and byte estimator follow DEL-17 and the chapter notes. |
| DEL-17 (merged) | confirmed | Same gap. Its closure-typed deleter is replaced by the protocol so an actor double can record calls. `assetResolver` is added now and consumed by WS-11. |
| BUILD-09 | confirmed | The host boots everything, and the 8 constructions default to `PhotoMLBridge.shared`. The proposed "shared-store stats before/after" test is replaced by a source lint plus a host-inertness check: a stats probe would itself open the shared store and could not see the other tests. |
| BUILD-19 | confirmed | 7 warnings at the cited lines, 3 doubles, and a 66-test catch-all. The acceptance grep is corrected: `': PHAsset'` also matches `asset: PHAsset()` literals. |

---

## WS-04 — P0 photo-review hotfixes

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M0 | M | WS-03 | no | `ws/04-photo-review-p0` |

**Primary files:** `iOSCleanup/Views/Photos/PhotoGroupDetailActionPolicy.swift` *new*, `iOSCleanup/Views/Photos/PhotoGroupDetailView.swift`, `iOSCleanup/Engines/DeletionManager.swift`, `iOSCleanup/Engines/PhotoDeletionGuardrails.swift`, `iOSCleanup/Views/Photos/SwipeModeView.swift`, `iOSCleanupTests/PhotoGroupDetailActionPolicyTests.swift` *new*, `iOSCleanupTests/DuckAssetCardImageKeyTests.swift` *new*, `iOSCleanupTests/DeletionManagerTests.swift`, `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`
**Findings covered:** DEL-01 (P0, confirmed; merged: UI-01), UI-02 (P0, confirmed), UI-15 (P2, confirmed; merged: DEL-16, VALUE-19)
**Decisions applied:**
- D-FREE-KEEPBEST — classifier Keep Best stays free on every eligible group, one group at a time.
- D-GATING, as a **temporary inline rule** that WS-36 replaces with `CleanupAccessPolicy`. In group detail these are free: any single-photo deletion, any strict subset of the recommendation, and a keeper swap that does not increase the delete count. Other custom multi-selections need Pro.

### Goal
In group detail the grid is the truth. Exactly one commit control is shown, its label states how many photos go to Recently Deleted, and it can only delete tiles the grid shows as marked. Manual edits survive the Compare round trip, and the user can choose a different keeper, which is recorded as a keeper override. In Duck Mode, every card shows the photo whose date, size and identifier are being decided.

### Current behavior (verified)
- `PhotoGroupDetailView.swift:81-89` renders `DuckPrimaryButton("Keep Best")` whenever `group.isAutoCleanEligible`, whatever `deleteSet` holds. Its action `keepBest()` (`:212-236`) calls `deletionManager.keepBest(from: group)` (`:218`), which deletes `group.deleteCandidateAssets`, the classifier's full plan (`DeletionManager.swift:105-107`, `:115-119`), and records feedback for the full plan.
- `:95-109` shows `DuckBottomActionBar` only when `!selectionMatchesRecommendation` (`:196-198`). The free-user label is "Delete Selected — Pro", and `isPaid` routes the tap to the paywall (`DuckBottomActionBar.swift:25-31`). A free user who unmarks a tile therefore has only Keep Best left, and Keep Best deletes that tile.
- `:119-124` `.task { deleteSet = group.isAutoCleanEligible ? Set(group.deleteCandidateIDs) : []; fileSizes = … }` runs on every appearance: after the `.fullScreenCover` Compare at `:128-136` is dismissed, and after tab switches.
- `toggleSelection` (`:162-194`) rejects the classifier keeper with "The recommended keeper is protected from deletion." even in review-only groups, and announces "Kept" or "Marked for deletion". The whole-group guard is at `:178-182`. `deleteSelected()` (`:238-277`) validates with `PhotoDeletionGuardrails.validateManualSelection` (`PhotoDeletionGuardrails.swift:170-186`, a strict non-empty subset) and deletes `deleteSet`.
- There is no keeper-change affordance: neither `PhotoGroupAssetCell` (`:280-461`) nor `FullscreenGroupCompareView` (`:482-551`, `keeperAssetID` = the classifier keeper) offers one. `PhotoReviewDecisionKind.keeperOverride` already exists (`Models/PhotoReviewFeedback.swift:21`). `PhotoFeedbackStore.recordSimilarGroupDecision(selectedKeeperID:…)` computes `recommendationAccepted` when it is passed nil (`PhotoFeedbackStore.swift:143-155`, `:680-690`).
- `PhotoGroupAssetCell` loads with `.task(id: "\(w)x\(h)")` (`:392`). That is safe today only because the `ForEach` is keyed by `localIdentifier` (`:57`).
- `SwipeModeView.swift:97-102`: `if let current = viewModel.current, case .asset(let asset, _) = current { DuckAssetCard(asset: asset, …) … }` has no `.id`. `SwipeModeViewModel.advance()` (`SwipeModeViewModel.swift:181-186`) skips month headers, so the branch stays true from card to card and SwiftUI keeps the view identity.
- `DuckAssetCard` (`SwipeModeView.swift:414-497`) holds `@State private var image` (`:419`) and loads with `.task(id: "\(Int(w))x\(Int(h))")` (`:482`). The task is keyed only by size, so card 2 onward shows card 1's bitmap while the date and size labels (read from `asset`) update. Duck Mode opens from "Smart Cleanup" (`PhotoDuckShellView.swift:240, 278-283`).
- The results-list Keep Best (`PhotoResultsView.swift:390-417`) has no user edits, so it correctly commits the full plan. It stays unchanged.

### Implementation plan

**WS-04.1 — Pure commit policy (DEL-01, UI-01, D-GATING)**
- **Why:** Removes "a photo the grid shows as Kept is deleted by Keep Best" and "an empty selection still deletes the full plan".
- **Change:** New file `iOSCleanup/Views/Photos/PhotoGroupDetailActionPolicy.swift`:
  ```swift
  import Foundation

  enum PhotoGroupDetailPrimaryAction: Equatable {
      case none
      case keepBest(deleteIDs: Set<String>)          // exactly the classifier plan
      case keepBestSubset(deleteIDs: Set<String>)    // strict subset, classifier keeper kept; free
      case deleteSelected(deleteIDs: Set<String>, keeperID: String?, requiresPurchase: Bool)
  }

  struct PhotoGroupDetailSelectionContext: Equatable {
      let assetIDs: Set<String>
      let suggestedKeeperID: String?
      let recommendedDeleteIDs: Set<String>   // empty unless the group is Keep Best eligible
      let isAutoCleanEligible: Bool
      init(group: PhotoGroup) { /* map from group; recommendedDeleteIDs = eligible ? Set(deleteCandidateIDs) : [] */ }
      init(assetIDs: Set<String>, suggestedKeeperID: String?, recommendedDeleteIDs: Set<String>, isAutoCleanEligible: Bool)
  }

  enum PhotoGroupDetailActionPolicy {
      static func effectiveKeeperID(_ keeperID: String?, in c: PhotoGroupDetailSelectionContext) -> String? {
          keeperID.flatMap { c.assetIDs.contains($0) ? $0 : nil } ?? c.suggestedKeeperID
      }

      static func resolve(_ c: PhotoGroupDetailSelectionContext, deleteSet: Set<String>,
                          keeperID: String?, isPurchased: Bool) -> PhotoGroupDetailPrimaryAction {
          let ids = deleteSet.intersection(c.assetIDs)            // stale IDs never commit
          guard !ids.isEmpty, ids.count < c.assetIDs.count else { return .none }
          let keeper = effectiveKeeperID(keeperID, in: c)
          if let keeper, ids.contains(keeper) { return .none }     // the keeper is never deletable
          if c.isAutoCleanEligible, keeper == c.suggestedKeeperID {
              if ids == c.recommendedDeleteIDs { return .keepBest(deleteIDs: ids) }
              if ids.isStrictSubset(of: c.recommendedDeleteIDs) { return .keepBestSubset(deleteIDs: ids) }
          }
          let free = isFreeManualSelection(ids, keeperID: keeper, in: c)
          return .deleteSelected(deleteIDs: ids, keeperID: keeper, requiresPurchase: !isPurchased && !free)
      }

      /// TEMPORARY (D-GATING): WS-36 replaces this with CleanupAccessPolicy.
      static func isFreeManualSelection(_ ids: Set<String>, keeperID: String?,
                                        in c: PhotoGroupDetailSelectionContext) -> Bool {
          if ids.count == 1 { return true }
          guard c.isAutoCleanEligible, let suggested = c.suggestedKeeperID,
                let keeperID, keeperID != suggested else { return false }
          return ids.isSubset(of: c.recommendedDeleteIDs.union([suggested]))
              && ids.count <= c.recommendedDeleteIDs.count        // a swap never increases deletions
      }
  }
  ```
  Add two pure reducers to the same enum:
  - `toggle(_ assetID:, deleteSet:, keeperID:, in:) -> ToggleOutcome`, where `enum ToggleOutcome: Equatable { case updated(Set<String>, nowSelected: Bool), rejectedKeeper, rejectedWholeGroup }`. It rejects the effective keeper and a selection that would cover every asset.
  - `promoteKeeper(_ newKeeperID:, deleteSet:, keeperID:, in:) -> (keeperID: String, deleteSet: Set<String>)`. It removes the new keeper from the set. **DECISION (owner may override):** in an eligible group, the previous keeper is inserted into the delete set, so "Keep this one instead" swaps roles and the delete count does not grow. In a review-only group nothing is auto-marked.
- **Edge cases:** `recommendedDeleteIDs` is empty for non-eligible groups, so they can only resolve to `.deleteSelected`. A group without any keeper resolves `keeper == nil` and relies on the strict-subset guard.

**WS-04.2 — Validated subset commit in DeletionManager (DEL-01)**
- **Why:** A narrowed Keep Best must go through the automated-plan guardrails and delete exactly the narrowed set.
- **Change:**
  - `PhotoDeletionGuardrails.swift`: add `static func validateKeepBestSubset(_ subset: Set<String>, in group: PhotoGroup) throws`. It runs `try validate(group: group)`, then requires `group.keeperAssetID != nil` (`.missingKeeperAssetID`), `!subset.isEmpty` (`.emptyDeleteCandidateList`), `!subset.contains(keeper)` (`.keeperIncludedInDeleteCandidates`) and `subset.isSubset(of: Set(group.deleteCandidateIDs))` (`.invalidManualSelection`).
  - `DeletionManager.swift`: add `func keepBest(from group: PhotoGroup, deleting subset: Set<String>) async throws`. It validates, sets `assets = PhotoAssetIdentity.unique(group.assets.filter { subset.contains($0.localIdentifier) })`, then shares the tail of `keepBestImmediately`: the pending-conflict guard with `keeperIDs = [keeper]`, `estimatedBytes`, `performDelete`, the totals, `recordConfirmedDeletion` and haptics. Extract that tail into `private func commitValidatedDeletion(of assets: [PHAsset], protectedKeeperIDs: Set<String>) async throws` and have both keep-best paths call it. `keepBest(from:)` keeps deleting the full plan.
- **Edge cases:** Stats are recorded only after the deleter returns. WS-11 later wraps this API in `DeletionResult`; keep the signature stable.

**WS-04.3 — Group detail: seed once, one control, keeper swap (DEL-01, UI-15, DEL-16, VALUE-19)**
- **Why:** Removes the reseed-on-reappear data loss and the missing keeper override.
- **Change (`PhotoGroupDetailView.swift`):**
  1. State: `@State private var deleteSet: Set<String>` and `@State private var selectedKeeperID: String?`, both seeded in `init` with `_deleteSet = State(initialValue: group.isAutoCleanEligible ? Set(group.deleteCandidateIDs) : [])` and `_selectedKeeperID = State(initialValue: group.keeperAssetID)`. In `.task`, keep only the `fileSizes` fill, guarded by `if fileSizes.isEmpty`.
  2. Derived values: `context = PhotoGroupDetailSelectionContext(group: group)`; `keeperID = PhotoGroupDetailActionPolicy.effectiveKeeperID(selectedKeeperID, in: context)`; `effectiveDeleteSet = deleteSet.intersection(context.assetIDs)`; `primaryAction = PhotoGroupDetailActionPolicy.resolve(context, deleteSet: deleteSet, keeperID: selectedKeeperID, isPurchased: purchaseManager.isPurchased)`. Delete `selectionMatchesRecommendation`.
  3. Bottom inset: delete the unconditional Keep Best block (`:81-89`) and the conditional bar (`:95-109`), and render exactly one control from `primaryAction`:
     - `.keepBest(ids)` and `.keepBestSubset(ids)`: `DuckPrimaryButton(title: isDeleting ? "Moving…" : "Keep Best · Move \(ids.count) to Recently Deleted")`.
     - `.deleteSelected(ids, _, requiresPurchase)`: `DuckBottomActionBar(summary: actionSummary, primaryLabel: isDeleting ? "Moving…" : "Move \(ids.count) to Recently Deleted", primaryEnabled: !isDeleting, isPaid: requiresPurchase, isDark: true, onPrimary: { Task { await commit() } }, onShowPaywall: { showPaywall = true })`.
     - `.none`: the same bar with `primaryEnabled: false` and the label "Move to Recently Deleted".

     Keep the existing error text and the "Potential space…" caption. `actionSummary` uses `effectiveDeleteSet`.
  4. `toggleSelection` calls `PhotoGroupDetailActionPolicy.toggle`:
     - `.rejectedKeeper`: `deleteError = "This is the photo you're keeping. To remove it, choose \"Keep this one instead\" on another photo."`, plus the existing haptic and announcement.
     - `.rejectedWholeGroup`: the existing `wouldDeleteEntireGroup` message.
     - `.updated`: assign, haptic, and announce "Marked for deletion" or "Kept".
  5. Keeper swap:
     - `promoteKeeper(_ id:)` applies the reducer and announces "Keeping this photo instead".
     - On `PhotoGroupAssetCell`, add `.contextMenu { Button { onKeepInstead() } label: { Label("Keep this one instead", systemImage: "star") } }` (only when `!isKeeper`) and `.accessibilityAction(named: "Keep this one instead", onKeepInstead)`. Rename the cell's `isRecommendedKeeper` to `isKeeper` and pass the effective keeper. The "Keeper" badge follows it.
     - `FullscreenGroupCompareView` takes `keeperAssetID: keeperID` and `onKeepInstead: (String) -> Void`, and shows a toolbar `Button("Keep This")` (`ToolbarItem(placement: .bottomBar)`) when `selectedAssetID != keeperAssetID`. Tapping it calls the closure and dismisses.
     - When `keeperID != group.keeperAssetID`, show the caption "You're keeping a different photo than suggested." under the review guidance.
     - For eligible groups, show a "Reset to suggestion" text button when the selection or keeper differs from the suggestion; it restores both.
  6. Replace `keepBest()` and `deleteSelected()` with one `commit()` that re-resolves `primaryAction` at tap time (never a captured value):
     - `.none`: return.
     - `.deleteSelected(_, _, requiresPurchase: true)`: `showPaywall = true` and return.
     - `.keepBest`: `deletionManager.keepBest(from: group)`, then feedback `.keepBest`, `selectedKeeperID: group.keeperAssetID`, `deletedAssetIDs: group.deleteCandidateIDs`, `keptAssetIDs: [keeper]`, `recommendationAccepted: true`.
     - `.keepBestSubset(ids)`: `deletionManager.keepBest(from: group, deleting: ids)`, then feedback `.keepBest`, `deletedAssetIDs: Array(ids)`, `keptAssetIDs: Array(context.assetIDs.subtracting(ids))`, `recommendationAccepted: nil`.
     - `.deleteSelected(ids, keeper, false)`: run `validateManualSelection(assetIDs: ids, in: group)` and `guard keeper.map({ !ids.contains($0) }) ?? true`, then `deletionManager.delete(assets: group.assets.filter { ids.contains($0.localIdentifier) })`, then feedback with kind `keeper != group.keeperAssetID ? .keeperOverride : .deleteSelected`, `selectedKeeperID: keeper`, deleted `ids`, kept = the rest, `recommendationAccepted: nil`.

     On success: `onDeleteGroup?()` and `dismiss()`. `catch is CancellationError` and `catch where DeletionManager.isUserCancellation(error)` both set `deleteError = nil` (a declined system prompt is an answer, not an error). Other errors keep today's message. `addSelectionToExportAlbum` uses `effectiveDeleteSet`.
  7. `PhotoGroupAssetCell`: change the image task id to `"\(asset.localIdentifier)|\(Int(w))x\(Int(h))"`. This hardens it the same way as Duck Mode.
- **Edge cases:**
  - If the parent re-creates the view with a regrouped `group`, State survives. `effectiveDeleteSet` and `effectiveKeeperID` drop stale IDs, and a vanished keeper falls back to the suggestion.
  - A purchase completing while the view is open re-resolves on the next render.
  - A double tap is guarded by `isDeleting`.
  - The keeper is never selectable, so validateManualSelection and keeper protection both survive.

**WS-04.4 — Duck Mode card identity (UI-02)**
- **Why:** Removes "every decision after the first is made against the wrong photo".
- **Change (`SwipeModeView.swift`):**
  1. At the call site (`:98`), put `.id(asset.localIdentifier)` directly on `DuckAssetCard(...)`, before `.clipShape`. Add `.accessibilityIdentifier("duck-card-\(asset.localIdentifier)")`.
  2. Add at the bottom of the file an internal `enum DuckAssetCardImageKey { static func make(assetID: String, size: CGSize) -> String { "\(assetID)|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))" } }`.
  3. In `DuckAssetCard`, add `@State private var loadedAssetID: String?`.
     - Render `image` only when `loadedAssetID == asset.localIdentifier`, and show the existing placeholder otherwise.
     - `.task(id: DuckAssetCardImageKey.make(assetID: asset.localIdentifier, size: targetSize))`: first, `if loadedAssetID != asset.localIdentifier { image = nil }`; then load; then `guard !Task.isCancelled else { return }`; then set `image` and `loadedAssetID = asset.localIdentifier`.
- **Edge cases:** No visual redesign: the same components, no new chrome. WS-51 later adds next-card prefetch and must keep `.id(asset.localIdentifier)` and this key. WS-14 later adds the "unavailable" state and disables Delete while it shows.

### Tests
All run in the simulator. The Duck Mode image behavior itself is device-verified (Vision cannot run in the simulator, so no groups exist there until WS-07).
- `iOSCleanupTests/PhotoGroupDetailActionPolicyTests.swift` uses the pure `PhotoGroupDetailSelectionContext(assetIDs:…)` init, plus one `PhotoGroup` built from `TestPhotoAsset`. The base context is `K + {A,B,C}`, recommendation `{A,B,C}`, eligible, suggested keeper `K`.
  - `testUntouchedEligibleSelectionResolvesToKeepBest`: `{A,B,C}` gives `.keepBest({A,B,C})`.
  - `testNarrowedSelectionResolvesToFreeKeepBestSubset`: `{A,C}` gives `.keepBestSubset({A,C})` for a free user.
  - `testEmptySelectionResolvesToNone`, `testSelectionContainingKeeperResolvesToNone`, `testWholeGroupSelectionResolvesToNone`.
  - `testAddingNonRecommendedPhotoRequiresPurchaseForFreeUser`: context with extra `F` not in the recommendation; `{A,B,F}` gives `.deleteSelected(requiresPurchase: true)`, and `false` when purchased.
  - `testSingleManualDeletionIsFree`: `{F}` gives `.deleteSelected(requiresPurchase: false)`.
  - `testReviewOnlyGroupMultiSelectRequiresPurchase`: non-eligible, `{A,B}`, gives `requiresPurchase: true` for a free user.
  - `testKeeperSwapWithinRecommendationIsFree`: keeper `B`, `{K,A,C}`, gives `.deleteSelected(keeperID: "B", requiresPurchase: false)`.
  - `testKeeperSwapThatIncreasesDeletionsRequiresPurchase`: keeper `B`, `{K,A,C,F}`, gives `requiresPurchase: true`.
  - `testStaleIDsOutsideGroupAreIgnored`: `{A,"gone"}` gives `.keepBestSubset({A})`.
  - `testToggleRejectsKeeperAndWholeGroup`; `testToggleAllowsSuggestedKeeperAfterSwap`.
  - `testPromoteKeeperSwapsRolesInEligibleGroup`: promote `B` from `{A,B,C}` gives keeper `B` and `{A,C,K}`.
  - `testPromoteKeeperDoesNotAutoMarkInReviewOnlyGroup`.
  - `testContextFromVisuallySimilarGroupHasNoRecommendation`: a real `PhotoGroup(reason: .visuallySimilar, …)` gives `isAutoCleanEligible == false` and an empty `recommendedDeleteIDs`.
  - `testResolvedDeleteIDsAreAlwaysAMarkedSubsetAndNeverTheKeeper` (exhaustive): 5 assets, every subset of `deleteSet` (32) × every keeper choice (5) × `isPurchased` (2). For every non-`.none` result, check:
    - the IDs ⊆ `deleteSet`;
    - the keeper ∉ IDs;
    - the IDs never cover the whole group;
    - `.keepBest*` only when the keeper == suggested and the IDs ⊆ the recommendation.
- `DeletionManagerTests` (additions, using WS-03's `RecordingDeleter`):
  - `testKeepBestSubsetDeletesExactlyTheSubset` gives `calls == [["A","C"]]`.
  - `testKeepBestSubsetRejectsKeeper`, `testKeepBestSubsetRejectsIDsOutsideRecommendation`, `testKeepBestSubsetRejectsEmptySubset` and `testKeepBestSubsetRejectsReviewOnlyGroup`: each throws and leaves `calls` empty.
  - `testKeepBestSubsetRecordsStatsForSubsetOnly`: bytes summed over the subset only.
- `iOSCleanupTests/DuckAssetCardImageKeyTests.swift`:
  - `testKeyDiffersForDifferentAssetsOfTheSameSize`
  - `testKeyIsStableForSameAssetAndSize`
  - `testKeyChangesWithSize`

### Acceptance criteria
- [ ] With any tile unmarked, no control in group detail can delete that tile. The only visible commit control's count equals the number of red-marked tiles (checked in the simulator once WS-07 lands, on device before).
- [ ] Unmarking tiles and returning from Compare keeps the selection.
- [ ] "Keep this one instead" works from the grid context menu, the VoiceOver action and Compare. The chosen keeper can never be marked. The commit records `.keeperOverride` with `selectedKeeperID`.
- [ ] A free user can commit a narrowed recommendation, a single photo and a non-growing keeper swap without the paywall. A wider custom multi-select shows the lock.
- [ ] `DuckAssetCard` has `.id(asset.localIdentifier)`, and its image task key includes the asset ID.
- [ ] All new tests pass, the full suite is green, and there are no new warnings.
- [ ] `ios-cleanup/CLAUDE.md` Paywall paragraph adds one sentence: "Group detail (temporary rule until WS-36): narrowing a Keep Best recommendation, a keeper swap that does not increase deletions, and single-photo deletions are free." The Navigation/Views notes say group detail seeds its selection once and supports keeper override.

### Device QA
Add to `docs/DEVICE_QA.md` (create the "Pending steps from chapter 01" section if the file does not exist yet).
1. Take 2 near-identical shots each of 2 different subjects (for example a mug and a plant) and run a scan. In Smart Cleanup (Duck Mode), card 1 shows subject 1 and card 2 shows subject 2. Each card's date and size match the photo, and after the commit the system dialog count matches the swipes.
2. Open an eligible group with a free account. Unmark one photo: the button reads "Keep Best · Move N−1 to Recently Deleted". Open Compare, tap Done: the photo is still unmarked. Commit, then check in Photos → Recently Deleted that exactly N−1 photos are there and the unmarked one is still in the library.
3. In the same kind of group, long-press a non-keeper → "Keep this one instead": the badge moves, the old keeper turns red, and the count is unchanged with no lock. Commit, and confirm the chosen photo remains.
4. With VoiceOver on, the actions "Toggle selection" and "Keep this one instead" are available on tiles.

### Pitfalls and out of scope
- Invariants: the keeper is never in a delete set, validateManualSelection stays, `visuallySimilar` groups never resolve to Keep Best, and all deletion goes through `DeletionManager`.
- Recording `.keeperOverride` (with `recommendationAccepted` computed as false) feeds `PhotoPreferenceProfile.keeperAcceptanceRate`, which today can downgrade Keep Best (`PreferenceAdjustedRecommendationService.swift:128-131`). WS-33 (chapter 07) removes preference-driven downgrades; do not change that service here.
- The central entitlement policy and moving the lock before the second selection are WS-36 (chapter 08). The typed `.declined`, the in-flight guard and the undo-state removal are WS-11 (chapter 03). Preview sizing, `PHImageManagerMaximumSize` in `ZoomablePhotoCanvas` and prefetch are WS-51 (chapter 11). Navigation stability during scans is WS-55 (chapter 12).
- No Duck Mode visual redesign; use existing Duck components and `Color.accentPrimary`.
- If WS-03 slips, land WS-04 anyway with the policy and key tests only (drop the DeletionManager subset tests to a follow-up). This is the top-priority P0.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| DEL-01 | confirmed | Keep Best renders independent of `deleteSet` and deletes the full plan; the only free path is Keep Best. Its resolver is adopted, extended with a `keeperID` input and `.none` for keeper/whole-group selections. |
| UI-01 (merged) | confirmed | Same bug. Its `canUseFreeKeepBest` input is dropped (D-FREE-KEEPBEST); its "single photo is free" rule is adopted per D-GATING. The "Reset to suggestion" button is included. |
| UI-02 | confirmed | There is no `.id`, the task is keyed by size only, and `advance()` skips headers, so identity persists. The fix combines `.id`, an asset-keyed task and a guarded render (`loadedAssetID`) so a stale bitmap can never show. |
| UI-15 | confirmed | The `.task` reseed runs on every appearance, and there is no keeper override. Seeding in `init`, plus a keeper swap recorded as `.keeperOverride`, is free when it doesn't increase deletions (D-GATING). |
| DEL-16 (merged) | partially | The limitation is real, but its fix (make the keeper tile directly selectable) would break the "keeper protection survives every refactor" invariant. Replaced by an explicit keeper swap, which reaches the same outcomes. |
| VALUE-19 (merged) | confirmed | Covered by the keeper swap; `selectedKeeperID` is recorded in feedback. |

---

## WS-05 — Export integrity (Export & Delete data-loss fixes)

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M0 | L | WS-01, WS-03 | no | `ws/05-export-integrity` |

**Primary files:** `iOSCleanup/Engines/ExternalPhotoExportService.swift`, `iOSCleanup/Engines/ExportResourceSource.swift` *new*, `iOSCleanup/Engines/ExternalPhotoResourceWriteState.swift` *new* (moved out of the service file and rewritten), `iOSCleanup/Engines/ExportIntegrity.swift` *new*, `iOSCleanup/Engines/ExportManifestStore.swift` *new*, `iOSCleanup/Engines/ExportResultNotes.swift` *new*, `iOSCleanup/Views/HomeView.swift` (≤ 10 lines in `ExportAlbumView`), `iOSCleanup/Views/Files/FileResultsView.swift` (≤ 3 lines), `iOSCleanupTests/ExternalPhotoExportServiceTests.swift`, `iOSCleanupTests/Support/FakeExportResourceSource.swift` *new*, `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`
**Findings covered:** FILES-01 (P0, confirmed), FILES-12 (P2, confirmed; merged: DEL-18), FILES-13 (P2, confirmed), FILES-14 (P2, confirmed), FILES-26 (P3, confirmed), plus one issue found during verification (manifest dates lose sub-second precision; see WS-05.5)
**Decisions applied:**
- D-MIGRATION — legacy per-run folders are linked by reference: their manifest entries are added to the destination manifest with relative sub-paths. Nothing is moved or deleted.
- D-EXPORT-DELETE is **not** changed here; WS-35/WS-36 own it. This workstream only defines which IDs are deletion-eligible.

### Goal
An exported item becomes deletion-eligible only when every byte PhotoKit delivered for that exact asset version is on the drive and the file's SHA-256 matches the streamed digest. A resume can never splice two assets. Manifest loss, kills and write failures can never erase export history or leave a verified file unrecorded, and legacy folders are never reorganized. The writer is race-free on cancel.

### Current behavior (verified)
Line numbers are for the working tree after WS-01 commits the WIP.
- **Partial naming (FILES-01):** `ExternalPhotoExportService.swift:661-670` derives `partialURL = directoryURL.appendingPathComponent(".\(filename).partial")` from the per-run output name (`uniqueFilename(preferredName: resource.originalFilename, assetIndex:…)`, which embeds `assetIndex` in disambiguated names). Cancellation keeps the partial (`:752-762`).
- **Resume:** `write()` (`:1152-1208`) resumes any existing file at that path via `verifiedByteCount` → `writeResumable(existingByteCount:)`. `ExternalPhotoResourceWriteState.receive` (`:1492-1571`) drops the first `bytesToSkip` delivered bytes (`:1511-1522`) without comparing them to disk.
- **Verification is size-only:** `byteCount == deliveredByteCount` (`:714-727`). When no partial exists, `write()` tries `writeDirect` first (`:1251-1298`), which returns `verifiedByteCount(at: destinationURL)` (`:1298`), so it compares the file with itself.
- **Deletion eligibility:** `HomeView.swift:1896-1897` makes `exportedAssetIDs ∪ alreadyExportedAssetIDs` eligible, and `:1931-1938` deletes them when "Export & Delete" was chosen. `ExternalPhotoExportResult.alreadyExportedAssetIDs` is documented "safe to delete from Photos" (`:141-143`) on the strength of `previouslyExportedAssetIDs` (`:1309-1341`), which checks a modification-date match plus the recorded size. `FileResultsView.swift:1189` is a second caller; it offers no deletion.
- **Manifest (FILES-13):** `loadManifestEntries` (`:1065-1079`) returns `[]` on any read or decode failure. `export()` passes that result as `existingManifestEntries` (`:504-506`), and `writeManifest` (`:866-892`) writes `existing + new` atomically, so an unreadable history is overwritten. The checkpoint rewrites the full manifest every 8 assets or 20 s (`:456-457`, `:805-837`), and its comment falsely claims unrecorded items "are re-detected as already-exported". The final `try? writeManifest`/`try? writeSession` (`:840-852`) discard errors.
- **Migration (FILES-12, WIP):** `migrateLegacyExportFolders` (`:937-1062`) moves files out of `PhotoDuck Export …` folders. It deletes a folder together with its manifest inside the loop (`:1045-1049`) before the merged manifest is written (`:1054-1060`, `try?`). A move followed by a failed size re-check leaves a file recorded nowhere. There is no cancellation check and no progress. `HomeView.swift:1901-1903` says "Moved N files here from earlier export folders."
- **Write state (FILES-14, WIP):** `receive()` releases `lock` and then calls `try fileHandle.write(contentsOf: blockToWrite)` (`:1549`). `cancel()` takes `lock` and calls `try? fileHandle.close()` (`:1630`) without waiting for an in-flight write. The class doc (`:1424-1426`) still claims every file-handle operation is under `lock`. The buffer is 32 MB (`:1430`). `receive` runs synchronously on PhotoKit's delivery queue, so download and write never overlapped; there is no throughput gain.
- **Dead code (FILES-26):**
  - `validateManifest` (`:1127-1148`) has no callers.
  - `ExternalPhotoExportCapacity` (`:336-368`) is used only by tests (`FileScanEngineTests.swift:1454-1510`); WS-57 plans to reuse it.
  - `ExternalPhotoExportSessionRecord` and `writeSession` (`:321-334`, `:545-554`, `:1092-1113`) write `.PhotoDuck Export Session.json`, which is never read. `ExternalPhotoExportSessionRecord.AssetSignature` **is** used for dedupe signatures.
  - `resumedAssetCount` is always 0 (`:587`).
  - There are two stacked doc comments at `:1301-1308`, and `totalBytes` starts as a convoluted zero (`:601-606`).
- **Found during verification (dates):** the manifest encoder and decoder use `.iso8601` (`:1648-1660`), which drops fractional seconds. Dedupe compares `entry.modificationDate == wantedVersion` exactly (`:1326`), so any asset whose `PHAsset.modificationDate` has a sub-second component is never recognised as already exported. The existing dedupe tests use whole-second dates and cannot see this. Whether PhotoKit dates carry fractions is device behavior; the fix below is correct either way.
- `PHAssetResource` has no public initializer and is not Sendable; `PHAssetResourceManager` is Sendable. Today the service calls `PHAssetResource.assetResources(for:)` (`:612-617`) and `resourceManager.requestData`/`writeData` directly, so the write path cannot be exercised in unit tests.

### Implementation plan
Commit per task. The suite must be green after each one. Do not reorder.

**WS-05.1 — Race-free write state with an I/O lock (FILES-14)**
- **Why:** Cancel during a 32 MB write to a slow USB drive closes the fd mid-write. That causes EBADF or a crash, or later writes land in whatever file reuses that fd number (for example the manifest).
- **Change:**
  - Move `ExternalPhotoResourceWriteState` to the new file `iOSCleanup/Engines/ExternalPhotoResourceWriteState.swift` as-is, then change it:
    - `private let ioLock = NSLock()` guards **every** `FileHandle` operation and `isHandleClosed`. `lock` guards `isFinished`, `continuation` and `requestID`. Never hold both locks at once.
    - `receive`: check `isFinished` under `lock`; under `ioLock`, do the buffer bookkeeping and any block write (skip if `isHandleClosed`); on a write error, close under `ioLock`, then finish under `lock`.
    - `cancel()`: set `isFinished` and take the continuation under `lock`. Then under `ioLock`, best-effort flush pending bytes (so the partial keeps all delivered progress), close, and set `isHandleClosed = true`. Then cancel the request and resume with `CancellationError`.
    - `complete(_:)`: set `isFinished` under `lock`, then flush, `synchronize()` and close under `ioLock`, then resume.
  - Replace `resourceManager: PHAssetResourceManager` with `cancelRequest: @escaping @Sendable (PHAssetResourceDataRequestID) -> Void`, and add `bufferByteCount: Int = 8 * 1_048_576` (back from 32 MB; internal, so tests can pass tiny values).
  - Rewrite the class doc to describe the two-lock rule, and remove the false "overlap" comment.
- **Edge cases:** A `receive` arriving after `cancel` is ignored. A `complete` after `cancel` is ignored (the existing test `testExternalResourceWriteStateCancellationWinsOverCompletion` stays). The continuation resumes exactly once.

**WS-05.2 — Testable PhotoKit resource seam (no behavior change)**
- **Why:** The splice scenario and the manifest-failure paths need service-level tests with fake bytes.
- **Change:** New file `iOSCleanup/Engines/ExportResourceSource.swift`:
  ```swift
  import Photos

  struct ExportResource: @unchecked Sendable {   // PHAssetResource is immutable but not Sendable
      let assetLocalIdentifier: String
      let type: PHAssetResourceType
      let originalFilename: String
      let photoKitResource: PHAssetResource?      // nil in tests
  }

  protocol ExportResourceSource: Sendable {
      func resources(for asset: PHAsset) -> [ExportResource]
      func requestData(for resource: ExportResource, allowNetworkAccess: Bool,
                       progress: @escaping @Sendable (Double) -> Void,
                       received: @escaping @Sendable (Data) -> Void,
                       completion: @escaping @Sendable (Error?) -> Void) -> PHAssetResourceDataRequestID
      func cancelDataRequest(_ requestID: PHAssetResourceDataRequestID)
  }

  struct PhotoKitExportResourceSource: ExportResourceSource {
      let manager: PHAssetResourceManager = .default()
      // resources: PHAssetResource.assetResources(for:).map { ExportResource(…, photoKitResource: $0) }
      // requestData: PHAssetResourceRequestOptions(isNetworkAccessAllowed, progressHandler) → manager.requestData;
      //   if photoKitResource == nil, call completion(ExternalPhotoExportError.resourceWriteFailed(name)) and
      //   return PHInvalidAssetResourceDataRequestID.
  }
  ```
  - `ExternalPhotoExportService.init(fileManager: FileManager = .default, resourceSource: any ExportResourceSource = PhotoKitExportResourceSource(), manifestStore: ExportManifestStore = ExportManifestStore(), writeBufferByteCount: Int = 8 * 1_048_576)`. Add `manifestStore` in WS-05.4; until then, keep the existing manifest functions.
  - `ExternalPhotoExportResourcePolicy.resources(for:available:)` operates on `[ExportResource]` with unchanged selection logic.
  - `writeResumable` calls `resourceSource.requestData`.
  - Keep `writeDirect` in this task; WS-05.3 removes it.
  - Test double `iOSCleanupTests/Support/FakeExportResourceSource.swift` (`final class …: ExportResourceSource, @unchecked Sendable`, with an `NSLock` and a private serial `DispatchQueue`):
    - `register(asset:filename:type:chunks:holdAfterChunks:)`.
    - `requestData` delivers the chunks asynchronously on its queue, then calls `completion(nil)`. With `holdAfterChunks: n` it delivers `n` chunks, yields the request ID on `let heldRequests: AsyncStream<PHAssetResourceDataRequestID>`, and stores the completion.
    - `cancelDataRequest` records the ID and calls the stored completion with `CocoaError(.userCancelled)`.
    - It exposes `requestCount`.
- **Edge cases:** `ExportResource` must not escape the actor except into the write state's closures.

**WS-05.3 — Identity-keyed partials, verified prefix, streaming SHA-256, hash-verified commit (FILES-01)**
- **Why:** Removes the splice: run 1 cancels clip A (`GOPR0001.MP4`, 1.2 of 3 GB); run 2 exports a different clip B with the same name, skips B's first 1.2 GB, passes the size check, and Export & Delete removes B.
- **Change:**
  - New file `iOSCleanup/Engines/ExportIntegrity.swift` (import CryptoKit, a system framework):
    ```swift
    struct ExportPartialIdentity: Equatable, Sendable {
        let localIdentifier: String, resourceType: Int, originalFilename: String
        let assetModificationTime: Double?              // timeIntervalSince1970, exact
        var key: String { String(SHA256.hash(data: Data(
            "\(localIdentifier)|\(resourceType)|\(originalFilename)|\(assetModificationTime.map { "\($0)" } ?? "nil")"
            .utf8)).hexString.prefix(32)) }
        var partialFilename: String { ".photoduck-\(key).partial" }
        var sidecarFilename: String { ".photoduck-\(key).partial.json" }
    }
    struct ExportPartialSidecar: Codable, Equatable, Sendable {
        static let schemaVersion = 1
        let schemaVersion: Int, localIdentifier: String, resourceType: Int, originalFilename: String
        let assetModificationTime: Double?, lastAttemptAt: Double   // app-written time, never a file timestamp
        func matches(_ identity: ExportPartialIdentity) -> Bool
    }
    enum ExportPartialStore {   // all static, takes fileManager; used only inside the service actor
        /// Returns the byte count to resume from (0 = fresh). A missing, unreadable or mismatched sidecar
        /// discards the partial. Always (re)writes the sidecar with lastAttemptAt = now before returning.
        static func prepare(_ identity: ExportPartialIdentity, in dir: URL, now: Date, fileManager: FileManager) throws -> Int64
        static func finish(_ identity: ExportPartialIdentity, in dir: URL, fileManager: FileManager)   // removes the sidecar
        static func discard(_ identity: ExportPartialIdentity, in dir: URL, fileManager: FileManager)  // removes both
        /// Removes `.photoduck-*.partial` + sidecar pairs whose sidecar is missing/unreadable, or whose
        /// lastAttemptAt is older than 7 days and whose asset is not in `requestedAssetIDs`. Returns bytes freed.
        static func sweepStale(in dir: URL, requestedAssetIDs: Set<String>, now: Date, fileManager: FileManager) -> Int64
    }
    enum ExportFileHasher {
        /// Streams the file in 8 MB chunks; checks Task cancellation between chunks.
        static func sha256Hex(ofFileAt url: URL) async throws -> String
    }
    extension SHA256Digest { var hexString: String { map { String(format: "%02x", $0) }.joined() } }
    ```
  - Write state (WS-05.1 file), new designated init `init(partialURL: URL, resumeFromByteCount: Int64, bufferByteCount:, cancelRequest:, onByteProgress:) throws`:
    - It opens `writeHandle = FileHandle(forUpdating:)` positioned at the end, plus `verifyHandle = FileHandle(forReadingFrom:)` when `resumeFromByteCount > 0`. It keeps `var hasher = SHA256()` and `deliveredByteCount`, both under `ioLock`.
    - In `receive(data)` (under `ioLock`): `hasher.update(data:)` first (every delivered byte, prefix included), then `deliveredByteCount += data.count`. While `remainingPrefix > 0`, read `min(remainingPrefix, data.count)` bytes from `verifyHandle` and compare them to the delivered bytes:
      - equal: they are verified and skipped;
      - on the first differing byte `i`: `writeHandle.truncate(atOffset: verifiedPrefix + i)`, set `remainingPrefix = 0`, close `verifyHandle`, and buffer `data[i...]`;
      - a short read counts as a mismatch at the short length.
    - In `complete(nil)`: if `remainingPrefix > 0` (PhotoKit delivered fewer bytes than the old partial held, all matching), `truncate(atOffset: deliveredByteCount)`. Then flush, synchronize and close, and publish `outcome = ExportStreamOutcome(byteCount: deliveredByteCount, sha256Hex: hasher.finalize().hexString, resumedPrefixByteCount: keptPrefix)`.
  - Service per-resource flow, replacing `:661-740` and `write()`/`writeResumable()`:
    ```swift
    let identity = ExportPartialIdentity(asset: asset, resource: resource)
    let partialURL = directoryURL.appendingPathComponent(identity.partialFilename)
    let resumeFrom = try ExportPartialStore.prepare(identity, in: directoryURL, now: now, fileManager: fileManager)
    let outcome = try await streamResource(resource, to: partialURL, resumeFrom: resumeFrom, onProgress: …)
    try Task.checkCancellation()
    guard try verifiedByteCount(at: partialURL) == outcome.byteCount,
          try await ExportFileHasher.sha256Hex(ofFileAt: partialURL) == outcome.sha256Hex else {
        throw ExternalPhotoExportError.verificationFailed(filename)
    }
    try fileManager.moveItem(at: partialURL, to: finalURL)
    committedAssetFiles.append(finalURL)                     // rollback covers it from here on
    guard try verifiedByteCount(at: finalURL) == outcome.byteCount else { throw … }
    ExportPartialStore.finish(identity, in: directoryURL, fileManager: fileManager)
    resourceEntries.append(.init(originalFilename: resource.originalFilename, exportedFilename: filename,
                                 resourceType: resource.type.rawValue, byteCount: outcome.byteCount,
                                 sha256: outcome.sha256Hex))
    ```
    - `catch is CancellationError` keeps the partial and sidecar and rolls back committed siblings, as today.
    - Any other error calls `ExportPartialStore.discard` and rolls back siblings.
    - **Delete `writeDirect` and its byte-monitor task.** Every resource streams through the hashing writer. This is the only way a writeDirect-written file could become hash-verifiable without a second PhotoKit read. It matches WS-57's "prefer cancellable requestData".
  - `ExternalPhotoExportManifest.AssetEntry.ResourceEntry` gains `var sha256: String? = nil`. Being optional keeps old manifests decodable, and the synthesized Codable omits it when nil.
  - At the start of `export()` (after the input checks), call `ExportPartialStore.sweepStale(requestedAssetIDs: Set(identifiers))`. Legacy-format partials (`.<name>.partial` without the `photoduck-` prefix) are **never** resumed and **never** deleted. **DECISION (owner may override):** they come only from unreleased builds and can't be attributed safely.
  - Add `ExternalPhotoExportResult.resumedByteCount: Int64` (the sum of `resumedPrefixByteCount`), replacing the always-zero `resumedAssetCount`.
- **Edge cases:**
  - The sweep uses the sidecar's app-written `lastAttemptAt`, never file modification dates. That keeps the user-picked folder out of the FileTimestamp category; WS-02 declared `C617.1` only.
  - Two resources of one asset with identical `originalFilename` and type are impossible in PhotoKit, but the key still includes the type.
  - An `assetModificationTime` change (the asset was edited) gives a new key, so the old partial is swept after 7 days.
  - The hash re-read doubles disk reads. Measure it on device (Device QA step 1).

**WS-05.4 — Manifest store: never erase history, journal instead of checkpoints (FILES-13)**
- **Why:** (a) A truncated manifest becomes `[]` and is overwritten with this run only. (b) A kill 7 items after a checkpoint leaves verified files unrecorded, and the next run re-copies them as `-1-1-1` duplicates. (c) A final write failure is silently reported as success.
- **Change:** New file `iOSCleanup/Engines/ExportManifestStore.swift`:
  ```swift
  struct ExportManifestStore: Sendable {
      typealias Writer = @Sendable (Data, URL) throws -> Void
      static let manifestFilename = "PhotoDuck Export Manifest.json"
      static let journalFilename = ".PhotoDuck Export Journal.jsonl"
      var writeFile: Writer = { try $0.write(to: $1, options: .atomic) }
      var appendLine: Writer = ExportManifestStore.appendLineDurably   // open for append, write, synchronize, close

      enum LoadOutcome: Equatable { case missing, loaded([ExternalPhotoExportManifest.AssetEntry]), unreadable }
      func load(in dir: URL) -> LoadOutcome                  // file-not-found → .missing; any other read/decode error → .unreadable
      func quarantineUnreadableManifest(in dir: URL, now: Date, fileManager: FileManager) throws -> String
          // renames to "PhotoDuck Export Manifest (unreadable yyyy-MM-dd HH-mm-ss).json" (en_US_POSIX); returns the name
      func write(_ entries: [ExternalPhotoExportManifest.AssetEntry], exportedAt: Date, to dir: URL) throws
          // writeFile, then re-read and decode; throws if the round-trip fails
      func appendToJournal(_ entry: ExternalPhotoExportManifest.AssetEntry, in dir: URL) throws  // compact JSON + "\n"
      func readJournal(in dir: URL) -> [ExternalPhotoExportManifest.AssetEntry]                 // malformed lines skipped
      func removeJournal(in dir: URL, fileManager: FileManager)
  }
  ```
  The journal needs a **compact** encoder with no `.prettyPrinted`; keep the pretty encoder for the manifest.

  Rewrite `export()`'s preamble in this order:
  1. `load`. On `.unreadable`, call `quarantineUnreadableManifest`. If the rename throws, throw the new `ExternalPhotoExportError.manifestUnreadable` ("PhotoDuck couldn't read this folder's export record and couldn't set it aside. Nothing was copied or deleted. Choose another folder.") before any file is written. On success, append the warning "An earlier export record couldn't be read; it was kept as <name>." to `result.recordWarnings`.
  2. Fold the journal: take entries whose resources all verify at the recorded size **and** carry `sha256`, replacing existing entries by `localIdentifier`.
  3. Link legacy folders (WS-05.6).
  4. If step 1 quarantined anything, or steps 2 or 3 changed anything, `write` the manifest. On success `removeJournal`; on failure add a record warning and keep the journal.
  5. Dedupe, as today.

  In `writeAssets`:
  - Delete the checkpoint cadence (`checkpointAssetInterval`, `checkpointSecondsInterval`, `:805-837`) and its false comment.
  - After each verified asset, `appendToJournal(entry)`. On success, add the ID to `recordedAssetIDs`; on failure, add a record warning once per run.
  - At the end, `write(existing + this run)`. On success `removeJournal`. On failure add the warning "PhotoDuck couldn't update the export record on this drive. Your copied files are safe; they will be recorded the next time you export here." and keep the journal.
  - Add `var recordWarnings: [String] = []` to `ExternalPhotoExportResult`.
- **Edge cases:** A journal line whose files are missing is dropped at fold time. Journal appends are O(1), so a 60k-item history no longer costs O(n) per checkpoint. **DECISION (owner may override):** an asset whose journal append failed is exported but **not** deletion-eligible this run (its record may not survive).

**WS-05.5 — Exact version matching across the manifest round-trip (found during verification)**
- **Why:** ISO8601 drops fractional seconds, so dedupe misses and every export re-copies items that are already exported.
- **Change:**
  - Add `var modificationTime: Double? = nil` (`timeIntervalSince1970`) to `AssetEntry`, and set it on every new entry.
  - Rename `ExternalPhotoExportSessionRecord.AssetSignature` to a top-level `struct ExternalPhotoExportAssetSignature` (same fields). Update `previouslyExportedAssetIDs` and the tests.
  - Add `static func isSameVersion(entry:current:) -> Bool` in `ExportIntegrity.swift`:
    - both nil gives true;
    - with `entry.modificationTime`, compare for exact `Double` equality;
    - with only a legacy `modificationDate`, accept `abs(diff) < 1.0` (ISO8601 truncation);
    - otherwise false.
- **Edge cases:** An edit made within the same second as the recorded legacy date would be missed; this applies only to legacy entries and is accepted.

**WS-05.6 — Legacy folders linked by reference (FILES-12, DEL-18, D-MIGRATION)**
- **Why:** The WIP deletes legacy folders and their manifests before the merged manifest is durable, and it silently reorganizes the user's drive.
- **Change:**
  - Replace `migrateLegacyExportFolders` with `func linkLegacyExportFolders(in dir: URL, knownAssetIDs: Set<String>) -> ExternalPhotoExportLegacyLinkResult`, which returns `{ entries: [AssetEntry], linkedAssetCount: Int, skippedFolderNames: [String] }`.
  - It visits subdirectories named `PhotoDuck Export …`, newest first, and `load`s each folder's manifest; an unreadable folder is skipped and its name recorded.
  - For each entry not already known, it rewrites every `exportedFilename` to `"\(folder.lastPathComponent)/\(name)"` and keeps the entry only if every file verifies at its recorded size. `sha256` stays nil.
  - It **never** moves, renames or deletes anything.
  - `export()` step 3 merges the entries.
  - Rename `migratedLegacyFileCount` to `linkedLegacyAssetCount`.
- **Edge cases:**
  - Reject resource names containing `/` or `..` before prefixing (a corrupt legacy manifest must not reach outside the folder).
  - Idempotent: a second run finds every ID already known and writes nothing.
  - `previouslyExportedAssetIDs` already resolves sub-paths via `appendingPathComponent`.

**WS-05.7 — One definition of deletion eligibility, and honest status text**
- **Why:** Today size-only matches are offered for deletion.
- **Change:**
  - Add `var deletionEligibleAssetIDs: [String] = []` to `ExternalPhotoExportResult`. It is (this run's exported IDs ∩ `recordedAssetIDs`) ∪ (already-exported IDs whose manifest entry has a non-nil `sha256` on every resource).
  - Add `var unverifiedAlreadyExportedAssetIDs: [String] = []`: already on the drive without hashes (pre-WS-05 or legacy-linked). **DECISION (owner may override):** these are skipped (never re-copied) but are **not** eligible for Export & Delete. No workstream adds a separate hash backfill. WS-35 (chapter 07) keeps this skip rule and narrows only deletion eligibility through `ExternalExportDeletionSafety.isDeletionSafe` (hash-verified per this workstream, and archival). It also adds an optional "Verify existing exports" pass (WS-35.7) that can upgrade these entries (README contract 31).
  - New file `iOSCleanup/Engines/ExportResultNotes.swift` with `extension ExternalPhotoExportResult { var supplementaryNotes: String }`, a pure function. It combines, in order:
    - " N already on this drive — skipped.";
    - " Found N items from earlier PhotoDuck export folders.";
    - " N items exported by an earlier PhotoDuck version can't be verified, so their originals stay in Photos.";
    - " Resumed X from an earlier attempt." (`ByteCountFormatter`);
    - each record warning.
  - `HomeView.swift` (`ExportAlbumView.exportAlbum(to:)`, `:1893-1917`): set `exportedAssetIDs = Set(result.deletionEligibleAssetIDs)`, and replace `skippedNote + migratedNote` with `result.supplementaryNotes` in the four status strings. Fix the comment at `:1893-1895`.
  - `FileResultsView.swift:1221-1233`: append `result.supplementaryNotes` to `completedExportMessage`. That is its only change.
  - Update the doc comment on `alreadyExportedAssetIDs` to "already on this drive; see `deletionEligibleAssetIDs` for what may be deleted".
- **Edge cases:** `deleteExportedOriginals()` keeps its "album changed after export" guard. If `deletionEligibleAssetIDs` is empty but items were exported, the post-export sheet does not offer deletion.

**WS-05.8 — Dead and misleading code (FILES-26)**
- **Change:**
  - Delete `validateManifest`, `ExternalPhotoExportSessionRecord` (the signature was already moved in WS-05.5), `writeSession`, and `sessionFilename` except for the one cleanup below.
  - At `export()` start, remove `.PhotoDuck Export Session.json` if present (PhotoDuck's own hidden file).
  - Remove `resumedAssetCount`, which was replaced in WS-05.3, and the stale doc comment at `:1301-1304`.
  - Change the `totalBytes` initializer to `var totalBytes: Int64 = 0`.
  - **Keep** `ExternalPhotoExportCapacity` and its tests, with a doc line "Not called in production yet; WS-57 wires the trusted capacity preflight."
  - Update `ios-cleanup/CLAUDE.md`: the `ExportAlbumStore / ExternalPhotoExportService` row becomes "streams every resource through SHA-256, commits only hash-verified files, journals each verified asset, links legacy folders by reference; deletion-eligible only with a hash match". The "External move safety" bullet adds "verified = size and SHA-256 match".

### Tests
All tests go in `iOSCleanupTests/ExternalPhotoExportServiceTests.swift` and run in the simulator using temp directories, `TestPhotoAsset` (`.video` or `.image`, with an explicit `modificationDate`) and `FakeExportResourceSource`. Tests never sleep; they synchronize on the fake's `heldRequests` stream.
- **Write state (WS-05.1, WS-05.3):**
  - `testWriteStateCancelNeverClosesTheHandleMidWrite`: a stress test with 200 iterations by default, overridable via the env var `PHOTODUCK_STRESS_ITERATIONS` (run 1,000 once locally and note it in the PR). Each iteration: `bufferByteCount = 4_096`; feed 50 × 16 KB chunks from one `DispatchQueue`; `cancel()` from another queue after a seeded-random chunk index; immediately afterwards, open and write a sibling file. Check that:
    - the continuation resumed exactly once (a counter under a lock);
    - there was no crash;
    - the partial's bytes are a prefix of the concatenated chunks;
    - the sibling contains only its own bytes.
  - `testWriteStateVerifiesResumedPrefixAndTruncatesOnMismatch`: partial `"wxyz"`, resume 4, deliver `"abcdefgh"`. The file is `"abcdefgh"`, the digest equals `SHA256("abcdefgh")` and `resumedPrefixByteCount == 0`.
  - `testWriteStateSkipsMatchingPrefix`: the adapted `testExternalResourceWriteStateResumesAnExistingPrefix`. Partial `"abcd"`, deliver `"abcdefgh"`: the file is `"abcdefgh"`, `resumedPrefixByteCount == 4`, and the digest covers all 8 bytes.
  - `testWriteStateTruncatesWhenDeliveryIsShorterThanPartial`: partial `"abcdefgh"`, deliver `"abcd"`, gives `"abcd"`.
  - `testWriteStateHashesEveryDeliveredByteAcrossChunks`.
  - The existing `…StreamsBytesAndFinishesOnce`, `…PreservesBufferedChunkOrder` and `…CancellationWinsOverCompletion` tests pass, adapted to the URL-based init.
- **Integrity helpers:**
  - `testFileHasherMatchesKnownVector`: `"abc"` gives `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`.
  - `testPartialKeyDiffersForSameFilenameDifferentAssets`, `…DiffersForDifferentModificationTime` and `…IsStable`.
  - `testPrepareResumesOnlyWithMatchingSidecar`, `testPrepareDiscardsPartialWithoutSidecar` and `testPrepareDiscardsPartialWithMismatchedSidecar`.
  - `testStaleSweepRemovesOnlyOldUnrequestedPhotoDuckPartials`: an old unrequested pair is removed; a recent pair, an old requested pair, a legacy `.IMG_1.MOV.partial` and a user file are untouched.
  - `testIsSameVersionHandlesExactAndLegacyTruncatedDates`.
- **Service (fake source):**
  - `testCancelledExportFollowedByDifferentSameNamedAssetNeverSplices` (required). Run 1: asset A, `GOPR0001.MP4`, chunks `["AAAA","AAAA"]`, `holdAfterChunks: 1`. Await `heldRequests`, cancel the task. Check `wasCancelled`, that `GOPR0001.MP4` doesn't exist, and that A's partial holds `"AAAA"`. Run 2: asset B, the same filename, `["BBBB","BBBB"]`. Check that `GOPR0001.MP4 == "BBBBBBBB"`, that the manifest entry for B has `sha256 == SHA256("BBBBBBBB")`, that `deletionEligibleAssetIDs == ["B"]`, and that A's partial is unchanged.
  - `testResumeOfSameAssetReusesVerifiedPrefix`: after run 1 above, re-export A. The file is `"AAAAAAAA"` and `resumedByteCount == 4`.
  - `testLegacyNamedPartialIsNeverResumed`: `.GOPR0001.MP4.partial` with `"AAAA"`, export B, gives `"BBBBBBBB"` with the legacy file untouched.
  - `testExportRecordsSHA256ForEveryResourceAndMarksItEligible`.
  - `testAlreadyExportedEntryWithoutHashIsSkippedButNotDeletionEligible` and `testAlreadyExportedEntryWithHashIsDeletionEligible`. In both, the fake's `requestCount` stays 0.
  - `testDedupeRecognizesAssetWithFractionalModificationDate`: export with `modificationDate = Date(timeIntervalSince1970: 1_700_000_000.123)`, then run again; the second run gives `alreadyExportedAssetIDs == [id]` and `requestCount` unchanged.
- **Manifest (WS-05.4):**
  - `testUnreadableManifestIsQuarantinedNotOverwritten`: `"{not json"` becomes a quarantined file with identical bytes, the new manifest has only the new entry, and `recordWarnings` is non-empty.
  - `testExportAbortsWhenUnreadableManifestCannotBeSetAside`: the injected `fileManager` rename fails, so it throws `.manifestUnreadable` and the fake's `requestCount == 0`.
  - `testJournaledAssetsAreRecognizedAfterKillBeforeManifestWrite`: write 3 journal lines plus files with hashes and no manifest. The next run's `alreadyExportedAssetIDs` contains all 3, and the journal is removed after the fold.
  - `testFinalManifestWriteFailureSurfacesWarningAndKeepsJournal`: `writeFile` throws, giving a warning, the journal still present and the asset still eligible (the journal append succeeded).
  - `testJournalAppendFailureMakesAssetIneligible`: `appendLine` throws, so the asset is exported but not in `deletionEligibleAssetIDs`.
  - `testManifestIsWrittenAtMostTwicePerRun`: 20 assets, and a counting `writeFile` sees ≤ 2 calls.
- **Legacy (WS-05.6)**, replacing the four `testMigration*` tests, which encode move semantics:
  - `testLegacyFoldersAreLinkedByReferenceAndLeftUntouched`: a recursive listing of paths and sizes is identical before and after, and dedupe recognizes `folder/IMG_1.HEIC`.
  - `testLegacyLinkIsIdempotent`.
  - `testLegacyEntryWithMissingFileIsNotLinked`.
  - `testLegacyEntryWithTraversalPathIsRejected`.
  - `testLegacyLinkWriteFailureChangesNothingOnDisk`.
- **Notes (WS-05.7):** `testSupplementaryNotesListsSkippedLegacyUnverifiedResumedAndWarnings` checks the pure string composition.
- **Cleanup (WS-05.8):** `testSessionFileFromOlderBuildsIsRemovedAtExportStart`.
- `ExternalPhotoExportCapacity` tests are unchanged.

### Acceptance criteria
- [ ] No code path commits a file unless its size and SHA-256 equal those of the bytes PhotoKit delivered for that asset version. `writeDirect` is gone.
- [ ] The required splice test passes; a resume after cancel reuses a verified prefix (`resumedByteCount > 0`).
- [ ] `deletionEligibleAssetIDs` is the only source of the Export & Delete set, and entries without `sha256` are never eligible.
- [ ] No sequence of unreadable manifest, kill or failed write erases prior records: quarantine plus journal, with warnings shown in both export UIs.
- [ ] Legacy `PhotoDuck Export …` folders are never moved or deleted.
- [ ] Every `FileHandle` write, synchronize and close holds `ioLock`, and the stress test passes 1,000 iterations locally.
- [ ] `validateManifest`, the session record, `writeSession`, `resumedAssetCount` and the duplicate doc comment are gone. `ExternalPhotoExportCapacity` is kept with its WS-57 note.
- [ ] Dedupe matches assets with fractional modification dates.
- [ ] The full suite is green with no new warnings. `ExternalPhotoExportService.swift` is shorter than before (logic moved to the new files). CLAUDE.md is updated.

### Device QA
Add to `docs/DEVICE_QA.md` (create the "Pending steps from chapter 01" section if needed). Use a USB-C SSD formatted exFAT plus the Files app.
1. Export a video of 1 GB or more with Export & Delete. Record the throughput shown and compare it with the WS-01 build on the same drive; note any slowdown over 25% in the PR, since the hash re-read and the removal of `writeDirect` both cost time. Afterwards, the system delete dialog appears only after "Verified", and `PhotoDuck Export Manifest.json` has a `sha256` for the file.
2. Put two different videos with the same original filename (for example two `IMG_0001.MOV` from different sources, or GoPro/DJI clips) into the Export Album. Start exporting the first and cancel at about 30%. Export the second alone, then play the file on a Mac: it is the second video. Re-export the first: it resumes ("Resumed …" note) and plays correctly.
3. Start a 20-item export and force-quit the app after about 8 items. Re-run: no `-1-1-1` duplicates on the drive, and the finished items are reported as already on the drive.
4. Export 3 photos, then export the same 3 again: the second run says "already on this drive — skipped" (checks the fractional-date fix).
5. On a drive that has `PhotoDuck Export <date>` folders from an older build: after an export, the folders and their contents are unchanged (compare on a Mac), those items are skipped, and the "can't be verified" note is shown.

### Pitfalls and out of scope
- Invariant: copy, verify (hash), manifest, then an explicit delete of verified IDs through `DeletionManager`; failures leave Photos untouched.
- Never read timestamps of files in the user-picked folder (the FileTimestamp reason is `C617.1` only). If that ever becomes necessary, add `3B52.1` in the same PR.
- These belong to later workstreams:
  - Archival export mode, the `exportMode` field, the delete offer on every path, the decline handling and the deletion-safety rule for legacy entries (`ExternalExportDeletionSafety`): WS-35 (chapter 07).
  - Paywall rules for deleting after export: WS-36 (chapter 08).
  - ENOSPC/EFBIG handling, the capacity preflight, a resume banner and background continuation: WS-57 (chapter 12). Deleting `writeDirect` here already removes FILES-15's `writeDirect` → `writeResumable` retry and FILES-16's uncancellable `writeData`; WS-57 covers only the remaining parts of those findings.
  - Unifying the two export orchestrations: WS-10 (chapter 02).
- After this workstream, no other workstream touches `ExternalPhotoExportService.swift` until WS-35. Keep `HomeView.swift` and `FileResultsView.swift` edits to the few lines listed (WS-10 moves `ExportAlbumView` right after).
- Reconciliation: (1) the Export Album function is `exportAlbum(to:)` (verified in `HomeView.swift:1819`); there is no `runExport`. (2) The earlier "hash backfill proposed for WS-35" was dropped, because chapter 07's WS-35 defines no backfill; it gates skip and eligibility through `ExternalExportDeletionSafety.isDeletionSafe`. (3) `deletionEligibleAssetIDs` is defined here; WS-10's `ExternalExportCoordinator.verifiedAssetIDs` and WS-35 build on this field and do not add a parallel one.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FILES-01 | confirmed | Name-derived partial, unchecked skip, size-only checks and self-comparison in `writeDirect` all verified. The plan adopts identity keys, a sidecar, prefix verification and a streamed hash. It differs in three ways: `writeDirect` is removed rather than hash-patched (a second PhotoKit read would be needed to verify it); the stale sweep uses the sidecar's app-written time instead of file modification dates (keeps the privacy manifest at `C617.1`); and the file is hashed before the rename. |
| FILES-12 | confirmed | Folder deletion precedes an unchecked `try?` manifest write, and a partial move leaves a file unrecorded. Resolved by D-MIGRATION: link by reference, no moves, so there is nothing to roll back. |
| DEL-18 (merged) | confirmed | Same defect. Its "roll back or record partial entry" fix is unnecessary once nothing moves. |
| FILES-13 | confirmed | `[]` on failure, overwrite-by-merge, a false checkpoint comment and discarded final errors all verified. Adopted: typed load, quarantine and journal. Added: abort before writing anything if quarantine fails, and "journal append failed ⇒ not deletion-eligible". |
| FILES-14 | confirmed | The write happens outside `lock` while `cancel` closes under `lock`. The crash or fd-reuse outcome is a runtime race, but the ordering flaw is certain statically. Adopted `ioLock` and 8 MB buffers; added flush-on-cancel so cancel keeps delivered progress. |
| FILES-26 | confirmed | All five items verified. `ExternalPhotoExportCapacity` is kept (WS-57 plans a preflight), and the dedupe signature type is preserved under a new name. |
| (new, unnumbered) | unverifiable-statically | The ISO8601 manifest dates drop fractional seconds while dedupe compares exactly; whether PhotoKit dates carry fractions is device behavior. The fix (an exact `modificationTime` plus a tolerant legacy comparison) is safe either way; Device QA step 4 confirms it. |
