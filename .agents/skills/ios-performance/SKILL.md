---
name: ios-performance
description: Performance and responsiveness practices for the Finances iOS app (SwiftUI, MobileLedgerStore, SQLiteJournalStore, CloudKit sync). Use when investigating freezes, stuck or laggy taps and swipes, slow registers or search, or sync hitches, and before changing MobileLedgerStore, SQLiteJournalStore, CloudKitJournalSyncCoordinator, or any list or register view.
metadata:
  scope: FinancesiOSApp (iOS 17+, Swift 6 language mode)
  companion-docs: docs/PERFORMANCE.md, AGENTS.md
---

# iOS performance practices for Finances

This skill is tool-agnostic. It applies to any coding agent or person working in this
repository. The rules below come from measured regressions in this app, not general
advice. When a rule and a measurement disagree, measure again, then update this file
and `docs/PERFORMANCE.md` together.

## 1. Where time goes in this app

Everything the user sees is driven by one `@MainActor` object, `MobileLedgerStore`
(`App/MobileLedgerStore.swift`). Know these pieces before touching anything:

| Piece | What it is | Cost characteristics |
| --- | --- | --- |
| `data: JournalData` | The published whole journal (ledgers, accounts, transactions, templates). Value type, copy-on-write arrays. | Assigning it republishes to every view holding `@EnvironmentObject store`. |
| `MobileLedgerDerivedCache` | Sorted/grouped transactions, balances, account trees, search text. | Full rebuild is O(n log n) over all transactions. Incremental `refreshDerivedCacheFor*` helpers are O(touched rows). |
| `deferredPersistenceQueue` | Serial GCD queue that owns SQLite writes and the committed baseline snapshot. | `.sync` onto it from the main actor blocks the UI for the whole write, including any write already queued. |
| `SQLiteJournalStore` | Diff-based persistence. Every public method opens a fresh connection and most take a process-wide `accessLock`. | Per-record calls in a loop are expensive; one transaction per logical operation is cheap. |
| `CloudKitJournalSyncCoordinator` | Pull, merge, upload passes; network on CloudKit's queues, SQLite on its own `databaseQueue`. | A pass runs on foreground, every 5 minutes, 0.5 s after each edit, on network changes, and on every push. Anything it does on the main actor repeats all day. |
| `RegisterPresentationCache` + `RegisterRenderWorker` | Off-main scope filtering, search, running balances, month sections, keyed by content revision. | Cached per revision; `clearTransactionListCaches()` throws every entry away. |
| `HistoricalTextSuggestionCache` | Per-journal payee/note index built on a worker. | Never scans on a keystroke; invalidate per journal, not globally. |
| `AccountBalanceProjection`, `MobileAppIconBadge`, `HomeScreenQuickActions`, `SystemEntryRouter.updateCatalog` | Side computations triggered by `data.didSet` or day changes. | Must stay O(1) on the main actor or hop to a detached task with a value snapshot. |

## 2. Rules for the main actor

1. **Never block the main actor on the persistence queue in a repeating path.** `deferredPersistenceQueue.sync` is acceptable only for a user-initiated atomic commit that must observe the current journal (imports, explicit saves, remote commits). Sync passes, timers, scene callbacks, and view updates must use the async flush (`cloudKitFlushLocalChangesAsync`, `flushLocalChangesAsync`, `scheduleDeferredLocalSave`).
2. **No O(n) work over transactions on the main actor per event.** Move it to `Task.detached` or an actor with a value snapshot wrapped in an `@unchecked Sendable` struct (see `AccountBalanceSnapshot`, `CloudKitJournalSnapshot`). Guard the result with a generation counter or an identity check before installing it.
3. **Check identity before rebuilding.** `JournalData.hasIdenticalContent(to:)` and plain array `==` return in constant time when storage is shared. Use them to skip validation, cache rebuilds, publishes, and file scans when nothing changed.
4. **Prefer incremental cache updates.** `refreshDerivedCache()` is the fallback for scope edits and imports. Single-row edits, cleared toggles, renames, template changes, and journal inserts all have targeted helpers; add a new helper rather than widening a call to the full rebuild.
5. **Publish only real changes.** Assign a `@Published` property only when the value differs (`if !flag { flag = true }`). Never reassign `data` with identical content. One stray publish per sync pass re-renders every screen.
6. **Validate once per journal value.** `validateLiveJournalIfChanged()` caches the last validated value and is cleared by `data.didSet`. Call it instead of `validateCandidateData(data, ...)` in flush paths.
7. **Keep `data.didSet` cheap.** Anything added there runs on every mutation. Compare inputs first (as `HomeScreenQuickActions.update` does) and defer real work.

## 3. Rules for SQLite

1. One transaction per logical operation. Fold per-record lookups into a single `withCloudKitDatabase` call (see `classifyCloudKitPull`).
2. Read only the keys you need. Never load a whole mirror table (`readKnownCloudKitRecords`) to answer questions about a page of records.
3. Encode only what you compare. The candidate guard uses `syncEnvelopes(for:limitedTo:)`; do not reintroduce whole-journal JSON encoding and hashing for a few outstanding edits.
4. Diff against the committed baseline; `persist(_:previous:)` already skips unchanged families by storage identity. Keep the baseline rule: it is read and written only on the persistence queue.
5. Long transactions on `CloudKitJournalSyncCoordinator.databaseQueue` hold `accessLock` and the SQLite write lock. Any main-thread `.sync` write waits for them (busy timeout is 8 s). Keep database-queue work short and never add main-thread sync writes that can overlap a pass.

## 4. Rules for CloudKit passes

1. An idle page (no records) must not touch the graph: bind the change token on the database queue and return.
2. Echo-only pages (this device's own uploads coming back) update bookkeeping only. They must not rebuild caches, invalidate registers, or reassign `data`.
3. Classification (pending outbox, known records for fetched keys, in-flight versions, acknowledgement receipts, receipt claims, pending descendants) runs on the database queue. Only merge, validation, and the atomic commit stay on the main actor. If the journal changed during the reads, redo them; the SQLite candidate guard is the last line of defense, not the first.
4. The flush at pass start and in the upload loop is awaited. Do not add synchronous flushes to the pass.
5. Known remaining cost: when another device really changed data, the merge still runs `refreshDerivedCache()` on the main actor once. Moving that off-main needs a precomputed cache handed into `cloudKitCommitRemote`; do not attempt it piecemeal.

## 5. Rules for SwiftUI views

1. Rows take value inputs and conform to `Equatable` (`RegisterRow`, `MobileAccountListRow`, `MobileTransactionPreviewRow`). Pass precomputed presentation structs, not the store.
2. `@EnvironmentObject store` makes a body re-run on every store publish. Keep bodies to dictionary lookups into derived caches; never filter or sort transactions inside `body`.
3. Registers render through `RegisterPresentationCache.load` with a `RegisterPresentationCacheKey` built from `registerContentRevision`. Reuse `scheduleRefresh`'s pattern: debounce revision changes, drop late results, and prewarm speculatively with `.utility` priority.
4. Search types through `RegisterRenderWorker.search` and the store's normalized-text caches. Do not call `transactions(scope:search:)` on every keystroke from a view.
5. Receipts: thumbnails come from `QLThumbnailGenerator` in a `.task(id:)`; never read file bytes or decode images on the main actor.
6. Disabling hit testing while content settles (`contentReady`) must always have a timed fallback that re-enables it.
7. Text input must not bind to a published property on a large observable object. Every keystroke republishes that object to every observer. Keep drafts in `@State` or in a small dedicated `ObservableObject` (see `AssistantComposerDraft`) observed only by the input row.
8. A view that only calls methods on a coordinator holds it as a plain `let`, not `@EnvironmentObject` or `@ObservedObject`, and subscribes to the one publisher it needs (`AppShellView` and `navigationRequest`). A `@StateObject` observes too; own a chatty object through a non-publishing holder when the owning view must stay still.

## 6. Diagnosing a freeze or laggy input

Work through this list in order; stop when the measurement points at a cause.

1. **Reproduce and time it.** Use Instruments (Time Profiler, Hangs, SwiftUI) on a device with a realistic journal. Simulator timings do not represent device frame pacing.
2. **Use the repo's own probes.**
   - `--demo-performance` launch argument with the demo data: `FinancePerformanceTrace.begin` marks actions and `.performanceDestination` marks their first layout; results are written to `FinancesiOS-Demo/performance-actions.json` inside the app's temporary directory when the app resigns active.
   - `--measure-startup` prints `startup.<phase>` timings.
   - `python3 scripts/benchmark_register.py` times register construction with synthetic data and no Simulator.
3. **Grep the hot paths.** Suspicious patterns on the main actor:
   - `deferredPersistenceQueue.sync` reachable from timers, scene phase, or sync.
   - `refreshDerivedCache()` where a targeted helper exists.
   - `validateCandidateData(` more than once per journal value.
   - `data = ` assignments with unchanged content; `@Published` writes without a change check.
   - Loops that call a `SQLiteJournalStore` method per record.
   - `.flatMap`, `.filter`, `.sorted` over `data.transactions` inside `body`, `didSet`, or `onReceive`.
4. **Count publishes per sync pass.** Temporarily log `objectWillChange` on `MobileLedgerStore` and run one pass with no remote changes. The expected number is small: the `lastSyncedAt` write at the end of the pass and the sync-state object's own progress updates. Anything else is a regression.
5. **Check sync trigger frequency** in `CloudKitForegroundSyncTriggers` (300 s fallback), `scheduleDeferredCloudSave` (0.5 s), scene activation, and push handling before blaming the UI.

## 7. Change recipe

1. Measure first and write down the number.
2. Find the main-actor work. Decide: skip it (identity check), make it incremental, or move it off-main with a snapshot and a guard.
3. Keep behavior identical. Performance changes in this repo must not alter sync semantics, validation, or UI. When replacing several queries with one, add an equivalence test that compares the batched result with the individual calls (see `testPullClassificationMatchesIndividualQueriesAndIdleTokenBindLeavesJournalUntouched`).
4. Run `scripts/test.sh --smoke` plus the suites that cover the changed area (`CloudKitJournalSyncTests`, `SQLiteCloudKitSyncTests`, `MobileCompanionTests`, `RegisterPresentationCacheTests`, `InteractionLatencyBenchmarks`). Never use live model inference or production endpoints for verification (see AGENTS.md).
5. Record the before/after numbers and the rationale in `docs/PERFORMANCE.md`. Keep the Xcode Cloud smoke selection unchanged; heavy benchmarks belong in `FinancesiOSFullTests`.

## 8. Files to know

- `App/MobileLedgerStore.swift`: store, derived caches, persistence, sync host conformance.
- `Core/SQLiteJournalStore.swift`: diff persistence, CloudKit mirror, outbox, batched readers.
- `Core/CloudKitJournalSyncCoordinator.swift`: pass lifecycle, classification, merge, upload.
- `App/RegisterPresentation.swift`, `App/RegisterPresentationCache.swift`: register math and caching.
- `App/HistoricalTextSuggestionCache.swift`, `Core/HistoricalTextSuggestionIndex.swift`: typing suggestions.
- `App/AccountBalanceProjection.swift`: daily balance rollover off-main.
- `App/FinancePerformanceTrace.swift`, `Core/StartupTiming.swift`: measurement hooks.
- `docs/PERFORMANCE.md`: history of measured changes.
