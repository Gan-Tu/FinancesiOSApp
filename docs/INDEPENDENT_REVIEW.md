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
