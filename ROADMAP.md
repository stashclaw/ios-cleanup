# PhotoDuck — Growth & Feature Roadmap

Based on July 2026 competitive research (CleanMyPhone, Swipewipe, Cleanup, Slidebox, Clever Cleaner, Kage, LuminaClean, Boost, Cleaner Guru + Apple built-ins) combined with the codebase review. Companion to FIXSPEC.md — fix P0/P1 there before building most of this. Items reference the code seams that make them cheap.

## Market context (one paragraph)

Cleaner apps are a ~$40M/month iOS category. The top grossers ($1–6M/mo) run $6–12/week subscriptions on paid ads targeting older users — a model publicly called predatory and drowning in 1-star subscription rage. Apple's built-in Duplicates album (iOS 16) only catches exact copies and hasn't advanced since 2022 — iOS 18/26 shipped zero new cleanup features. The open wedge: **honest, on-device, pay-once, accurate similar-photo cleanup** — "everything after Apple's exact-dupe pass." Clever Cleaner (free) and LuminaClean ($17.99 lifetime) are already winning Reddit/press coverage on exactly this axis.

## Positioning

- Headline: **"Pay once. No subscription. Ever."** — stated in-app, on the paywall, and in the App Store subtitle. A Swipewipe reviewer literally begged for this option; Swipewipe's own pre-acquisition data showed users overwhelmingly chose lifetime over monthly when offered both.
- Trust language everywhere MacPaw uses it: "100% on-device. Your photos never leave your iPhone. No account, no tracking." This is already true of the architecture — say it loudly.
- Position against Apple: concede exact duplicates to the built-in Photos album; own similars, bursts, blur, screenshots, video compression, and the review workflow. (Bonus: iOS's "Clean Up" is an object eraser, not storage cleanup — searchable confusion our marketing can answer.)

## Pricing (decision needed)

Current $2.99 one-time is 6–16x below every competitor lifetime tier ($17.99–$49.99) and below Kage's *weekly* price.

**Recommended: single lifetime unlock at $19.99** (launch promo $14.99), 3-day trial optional, keep a real free tier (see FIXSPEC 0.3). Rationale: undercuts every lifetime competitor, preserves the anti-subscription identity that is the entire organic-growth strategy, and zero server cost makes lifetime pure margin. Grandfather existing $2.99 buyers (check original purchase via StoreKit).

**Revenue-max alternative** (only if pursuing paid UA later): hybrid paywall, annual $29.99 w/ 3-day trial (highlighted, shown as "$0.58/week") + lifetime $49.99 anchor. Category data: hybrid buyers are 7% of buyers but 25% of revenue; lifetime performs best in Photo & Video of all categories. Note this conflicts with "No subscription. Ever." copy — pick one identity.

Paywall compliance either way: price/term/title displayed, working Privacy Policy + Terms links (3.1.2 — most common rejection), all savings numbers real computed values (2.3.1).

## Feature roadmap

### Tier 1 — missing table stakes (comparison-chart parity; build first)

1. **Screenshots & screen recordings category** — every competitor has it; one-line `mediaSubtypes` predicate on the existing PHAsset enumeration. The canonical "safe bulk delete" that gives free users an easy win and reviewers a big number.
2. **Blurry-photo detection** — shipped by all four leaders. Cheap: Laplacian variance on the 224px thumbnails the scan already decodes, or reuse the existing sharpness component of best-shot scoring (`SimilarReviewServices` framing/resolution weights) inverted into its own category.
3. **Storage-saved meter + lifetime "GB freed" stats** — the emotional payoff behind every 5-star review in the category ("cleared 12 GIGABYTES"). `DeletionManager` already tracks `totalBytesFreed`; surface it: per-session recap, lifetime counter on Home, real before/after via `volumeAvailableCapacityForImportantUsage`. Replaces the fabricated storage bar (FIXSPEC 0.11.5). Must be honest about Recently Deleted (30-day lag) — competitors aren't; a "finish the job" deep link is a trust differentiator.
4. **One-tap Smart Cleanup across all groups** — bulk "Keep Best everywhere" with a thumbnail review sheet before commit. Clever Cleaner's most-praised feature. The engine already computes per-group keepers + `isAutoCleanEligible`; this is UI + the FIXSPEC 3.4 review sheet.
5. **Live Photo → still conversion** — only CleanMyPhone and Clever Cleaner have it; real GB savings. Detect `.pairedVideo` resources (resource enumeration already exists in FileScanEngine), re-save still, delete pair — reuses VideoCompressionEngine's save-then-delete machinery.

### Tier 2 — differentiators (pick 2–3; these drive positioning)

6. **Monthly cleaning ritual + recap** — Swipewipe's $1M/month engine. SwipeModeViewModel already has month headers: extend to per-month progress ("June: 84 photos to review"), a "July Cleanup" card on Home that resets monthly, and an end-of-month recap screen (photos reviewed, GB freed, best-of month). Streak = consecutive months cleaned (monthly cadence is harder to break than daily and matches real usage).
7. **Shareable recap card** — "I freed 3.2 GB with PhotoDuck 🦆" render-to-image share sheet. Swipewipe's growth was TikTok-driven; this is the organic-UA engine. Duck mascot makes it distinctive.
8. **Widget** — home/lock-screen: reclaimable-GB gauge + "X photos to review this month" (WidgetKit, reads the persisted cleanup state — `photoduck.cleanup-state.v2` already stores what's needed). Pair with ONE monthly notification: "Your camera roll grew 2.1 GB in July." Soft pre-prompt for notification permission (not mid-scan — FIXSPEC 3.4).
9. **Similarity sensitivity slider** — only two minor competitors have it; directly answers the category's #1 accuracy complaint ("groups unrelated photos"). Cheap: the engine already computes distances; expose conservative/normal/aggressive presets mapping to threshold sets in `SimilarityPolicyTypes`. Safe default; recompute groups from cached pair signals without re-running Vision (needs FIXSPEC 2.3 cache read-back).
10. **Hold-to-preview video feed** — TikTok-style scrollable feed for the large-video list (only Kage has this). Makes the highest-GB-per-tap category fun; pairs with existing compression flow and the batch-compression queue.
11. **Duplicate video detection** — nobody does it well; cheap first pass on duration + resolution + byte size from data FileScanEngine already collects.

### Tier 3 — later

12. App Shortcut / App Intent ("Clean my screenshots") — cheap hygiene, Spotlight/Siri surface.
13. AI theme organization (Travel/Pets/Food — CleanMyPhone's Organize) — big lift, different product direction; only if Tier 1–2 exhausted.
14. Email/calendar cleanup — Cleanup's differentiator; off-mission for a photo brand, skip.

## Performance playbook (real + perceived speed)

Field-proven patterns from this exact niche (ShutterSlim, MWM/Swipewipe engineering posts), mapped to our code:

1. **Time-bucket pre-clustering** — start a new candidate bucket when >10 min separates consecutive photos; near-dupes are taken seconds apart. Cuts a 35k-photo library from ~600M pair comparisons to a few hundred thousand. The engine's 240-asset sliding window partially does this; an explicit time-gap cut on top is nearly free and shrinks the window's work further.
2. **Incremental rescans** — read back the persisted pairwise/feature cache (it's currently write-only — FIXSPEC 2.3) keyed on `localIdentifier` + `modificationDate` + embedding version. Second scan of a stable library should be under a minute; "instant second launch" is the single biggest perceived-speed win.
3. **Delta scans, not library scans** — with the change observer (FIXSPEC 0.9): "12 new photos since Tuesday — scanning" instead of a full progress bar.
4. **Scan during onboarding** — kick off the scan on the last onboarding screen so Home lands with results already streaming. The scan is the demo; then show "We found 1,847 removable photos — 3.2 GB" before any paywall.
5. **Progressive results + skeletons** — the engine already streams group batches; make the UI render the first groups within 1–2 s with skeleton cells and a counting-up "X GB found" number (measurably increases wait tolerance).
6. **Background index** — `BGProcessingTask` (`requiresExternalPower`) to pre-index overnight; on iOS 26, `BGContinuedProcessingTask` gives user-initiated scans system progress UI that survives backgrounding.
7. **Pin the Vision revision (FIXSPEC 1.19 — now urgent):** feature-print scales differ drastically by revision (iOS 17+ rev 2: normalized 768-dim, useful thresholds ~0.4–0.6; iOS 16 rev 1: non-normalized, thresholds ~11). Our fixed 0.16/0.05 thresholds are only valid for one revision — pin it, stamp cached prints with it, invalidate on change. Use Accelerate (`vDSP_distancesq`) for distance math.
8. Also see FIXSPEC 2.1–2.6 (comparator waste, per-swipe archive rewrite, decode spikes, Equatable churn).

## ASO notes (brief)

- Target long-tail intent keywords ("delete duplicate photos", "similar photo cleaner", "compress video iphone"), not head terms — incumbents outspend on "phone cleaner" with $6M/month budgets.
- Screenshot order that converts in this category: (1) big GB-freed number / before-after bar, (2) swipe UI in motion, (3) duplicate grid with "Best" badge. Title packs function keywords: "PhotoDuck: Duplicate Photo Cleaner."
- Review-prompt timing: after a successful cleanup session (the "freed X GB" moment), never before.
- The differentiation line competitors cannot copy: "100% on-device · no tracking · no account · no weekly subscription."

## Sequencing suggestion

1. FIXSPEC P0/P1 (working, honest, safe app).
2. Tier 1 features + performance playbook items 1–2, 4–5 (parity + feels instant).
3. Pricing change + paywall rebuild (with FIXSPEC 0.3 free-tier decision).
4. Tier 2: monthly ritual + recap + widget + share card (retention/growth loop).
5. ASO pass + launch.
