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
