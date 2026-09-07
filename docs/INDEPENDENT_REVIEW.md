# Independent review — September 7, 2026

Baseline `79fb240` was pushed before review and its Xcode Cloud release succeeded. The original FinanceClone files remain unchanged.

## Round 1

A separate read-only reviewer examined application code, shared persistence/sync/recurrence code, tests and release configuration. It identified five actionable issues:

1. Cleanup could recursively remove a folder containing referenced receipts.
2. A failed backup restore could overwrite existing receipt bytes before validating or durably replacing the journal.
3. Independently valid account moves could merge into a cyclic hierarchy and crash cache rebuilding.
4. Ordinary CloudKit commits relocked an already-unlocked session despite unchanged credentials.
5. Finite repeating schedules could never advance past the first 2,400 attempted slots.

The fixes collect only receipts removed from a successfully committed snapshot, stage backup receipts at new paths, atomically replace journal and sync metadata, reject cyclic account graphs, preserve unchanged unlock state, and finish recurrence generation in bounded allocation chunks without changing wire fields. Obsolete cleanup and direct backup-write helpers were removed.

All 59 focused mobile-store, SQLite/CloudKit and recurrence tests passed. New cases cover nested receipts, incomplete/invalid backups, injected SQLite restore failure, unsaved editor receipts, unchanged and conflicting sync pulls, invalid hierarchy checkpoints, and schedules exceeding 2,401 rows with workday collisions and moved/deleted occurrences. The two initial assertion failures were order/serialization differences between in-memory and persisted fixtures; tests now compare canonical persisted snapshots or unordered account sets.

A fresh review of the patched source follows before the final release push. These are bounded code reviews, not a claim that all possible bugs have been excluded. Actual camera capture and Apple's external beta approval remain separate from the verified automated internal release.

## Round 2

A fresh reviewer verified the original fixes and reproduced two additional receipt issues: failed CloudKit attempts still need their original bytes after a local delete/restore, and original-database import confused absolute source receipt paths with local destinations. The fixes retain active upload paths until acknowledgement, collect completed unreferenced claims after successful sync, and import external receipts into new paths before a durable journal replacement. Tests cover retry after reopen, both deletion and restoration, correct imported bytes despite stale local files, and rollback on an injected database failure.

A separate UI lifecycle regression also confirmed that the old lock overlay did not cover an already-presented editor. A scene-local lock window now covers every presentation, blocks underlying interaction/accessibility, and preserves the unsaved editor. It displays an opaque background and handles incorrect passwords in the lock view. The new lock test failed before the fix and passed afterward.

All 23 focused mobile and lock-UI checks passed after these changes. A further independent review and complete suite follow before the final push.

## Round 3

The third independent reviewer reproduced one remaining issue: a remote deletion guarded receipt identity but could delete a file still shared by another surviving asset. The coordinator now checks retained canonical file paths, including active upload attempts, before moving/deleting a receipt. Remote receipt relocation also collects only obsolete files after a successful database commit. Regression cases cover a shared file surviving a remote asset deletion and a relocated receipt surviving reopen without leaving the old copy behind.

The complete suite at `d3a654c` passed **148 tests**, with the opt-in physical-device acceptance test skipped. After the final receipt-reference changes, all **131 domain/storage tests** passed. The synthetic remote-deletion test initially reused an already-acknowledged mutation identifier; correcting the fixture to create a new remote mutation made the intended deletion scenario valid.

Final independent re-review follows on the committed receipt-reference fix before release.

## Round 4 — complete

Independent re-review of `839d7fda82568bae9b2505e88753e8939fee8d2b` found **no actionable findings**. The reviewer independently reran the former shared-file failure, sole-owner deletion, and injected commit rollback probes against the committed production helper. All behaved correctly. The queue-order concern raised during review was ruled out: inbound receipt installation follows a synchronous local-write flush and does not yield before commit.

The final application source is unchanged after this review; subsequent changes record verification and the separate iOS Cloud release ownership. Four review passes were completed using three independent reviewer agents, with fixes and regression checks between rounds.

## Hosted test-runner follow-up

Build100 completed Apple's required tests/archive/internal distribution, but the independent GitHub run hit two ten-second harness timeouts during its first controlled CloudKit cases. The same runner's next passing case took9.746seconds before subsequent cases returned to subsecond timings. Harness observation bounds are now30seconds with progress/call diagnostics; application deadlines and all outcome assertions are unchanged. TestFlight notes are checked in so future automatic releases include testing guidance.

The adjusted sync harness passed all37 sync tests locally. The iOS runtime source remains the independently reviewed `839d7fd` version. Build100 is internally distributed and submitted for external review; the old C33 workflow is disabled. A CI-only re-review precedes the final follow-up push.
