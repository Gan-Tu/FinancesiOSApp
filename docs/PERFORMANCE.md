# Large-journal register performance

Measured on September 7, 2026 with optimized Swift builds on the same Mac. Values are medians of three register preparations. Each synthetic journal has 200 asset accounts and a dense month of balanced transactions.

| Transactions | Register | Before (`92f200c`) | After |
| --- | --- | ---: | ---: |
| 10,000 | All | 274 ms | 117 ms |
| 10,000 | Account group | 1,266 ms | 105 ms |
| 30,000 | All | 1,782 ms | 340 ms |
| 30,000 | Account group | 4,713 ms | 317 ms |

Run `python3 scripts/benchmark_register.py` from the repository. It compiles the actual model and register calculation in a temporary package, with no personal data, network services, or Simulator. The benchmark includes transaction metadata; phone frame rates and receipt image loading require separate device profiling.

Changes:

- Mutate cash-flow buckets in place to avoid repeatedly copying growing transaction-ID sets.
- Accumulate group balances with postings instead of summing every descendant for every row. Multi-currency accounts retain the existing currency-specific projection.
- Ignore sync-only metadata changes when deciding to rebuild the register, and debounce search typing.
- Keep transaction/account row inputs value-based so unchanged rows can skip rebuilding.
- Refresh sync conflicts on completion, cancellation, or failure instead of querying SQLite for every progress update.

Focused checks cover split totals/transaction IDs, filtered running balances, multi-currency transitions, single-currency group totals, and content invalidation. Receipt previews already use asynchronous Quick Look thumbnails; their implementation is unchanged.

## iCloud sync passes and the main thread (October 2, 2026)

Reports of random freezes and unresponsive taps pointed at work that every iCloud sync pass performed on the main actor. Passes run on each foreground activation, five minutes apart, half a second after every edit, on network changes, and on every push notification, so the cost repeated throughout a session:

- Each pass flushed local changes three to four times with a synchronous wait on the serial SQLite writer, validating the whole journal and collecting every stored receipt path each time.
- The pull commit ran even when iCloud returned no records. It read the entire known-record mirror and the outbox on the main thread, opened one SQLite connection per fetched record to check acknowledgement receipts, rebuilt every derived cache (sorted transactions, balances, account trees, search text), invalidated every cached register, and republished the journal to every view.
- When unsynced edits were waiting, the SQLite candidate guard re-encoded and hashed every record in the journal while the main thread waited.

Changes:

- A page with no records now binds the change token on the sync database queue and returns. Nothing is read, merged, rebuilt, or republished.
- Record classification (pending outbox, known mirror entries for the fetched keys only, in-flight versions, acknowledgement receipts, receipt upload claims, pending descendants) runs in one SQLite transaction on the database queue. Only the merge, validation, and commit remain on the main actor; an edit that lands during the reads restarts them, and the existing SQLite guard still rejects a stale merge.
- Echo-only pages (this device's own uploads coming back) update sync bookkeeping without rebuilding derived caches, invalidating registers, or reassigning the published journal.
- Sync-driven flushes await the serial writer instead of blocking on it, validate the journal once per value, and skip the receipt-path scan when transaction storage is unchanged.
- The candidate guard encodes only the records with outstanding local edits.

Verification: `SQLiteCloudKitSyncTests` compares the batched classifier against the individual queries it replaced and checks that an idle token bind leaves the journal, outbox, and mirror untouched. `CloudKitJournalSyncTests` confirms that an empty page advances the checkpoint without reaching the host commit while echo pages still do. Device profiling of frame pacing during a pass was not part of this change.

## Ask AI composer typing (October 2, 2026)

Typing in the chat lagged by whole words. The draft text was a published property of `AssistantCoordinator`, so every keystroke republished the coordinator to every observer: the chat transcript (Markdown bubbles), the attachment menu, `AppShellView`, and the root content view that owned the coordinator through `@StateObject`. The shell re-render reached the pushed register and journal screens behind the sheet. Streamed reply tokens took the same path.

Changes:

- The draft lives in `AssistantComposerDraft`, a separate observable object. Only `AssistantComposerBar` (input, dictation, attach, send) observes it, so a keystroke re-renders that row alone. `AssistantCoordinator.draftText` remains as a pass-through accessor.
- `AppShellView` holds the coordinator as a plain reference and receives navigation requests through the request publisher instead of observing the whole object.
- The root content view owns the coordinator through a non-publishing holder object, so streamed tokens and status changes no longer re-render the navigation shell.

- Run-loop checkpoints (`persistAsync`) publish state at once and run JSON encoding plus the SQLite write on a serial history queue that the loop awaits. Immediate user actions still write synchronously through the same queue, so write order is unchanged. A long conversation no longer stalls the main thread several times per step while the user types a follow-up.
- Streamed tokens are published in 60 ms batches instead of one Markdown re-render per token; `activity` publishes only when its text changes.
- `MobileLedgerStore.data` is published by hand so the sync-timestamp write at the end of every pass, which no view renders, no longer re-renders every screen.

Verification: `AssistantTests` asserts that appending to the draft publishes the draft object only, never the coordinator; its run-loop tests cover the awaited checkpoints. Device frame pacing while typing and streaming was not measured as part of this change.

## Daily stalls: repeating entries and the end of every sync pass (November 17, 2026)

Reports described the app getting stuck for a moment during ordinary use, almost every day, as if background work were blocking the interface. Three causes were found by reading the main-actor paths and measuring the heaviest one.

**Repeating entries.** `RecurringJournalEditor.materialized` runs on the main actor at every launch and on the first foreground of each day. For every repeating rule it rescanned the whole journal several times: once with a calendar call per one-off transaction to find the horizon, again to find the rule's rows and anchor, and again to rebuild the set of all IDs. It also hashed an identity for every slot, including slots whose day was already taken, and built each identity with sixteen `String(format:)` calls.

| Synthetic journal | Before | After |
| --- | ---: | ---: |
| 10,197 transactions, 24 repeating rules, daily top-up | 292 ms | 19 ms |

Medians of three runs in an optimized build on the same Mac; a phone is slower. Changes, none of which alter the output:

- The journal is indexed once per call (`MaterializationIndex`: latest one-off date per journal, each rule's rows and positions, all IDs) and kept current as occurrences are appended. Materialization only appends, and generated occurrences always carry their rule, so the one-off dates cannot change during a call. The latest one-off day is the start of day of the latest one-off date, because the start of a day only moves forward with time.
- A slot whose day is already taken is skipped before its identity is hashed.
- Identities are built from the digest bytes directly. The resulting UUIDs are identical; `RecurringJournalEditorTests` pins two known values because these IDs are synced between devices.

The new code was compared with the previous implementation on 3,720 randomized cases (four time zones, daily/weekly/monthly/yearly rules, intervals, workday shifting, counts, end dates, deleted slots, continuation cursors, far-future one-off entries, and schedules needing several 2,400-row batches) with zero differences in the resulting transactions.

**Every sync pass.** Passes run after each edit, on each foreground, every five minutes, and on each push:

- The pass asked whether the known mirror was empty by reading and decoding every mirrored record while holding the process-wide SQLite lock. It now asks SQLite with `hasKnownCloudKitRecords` (`SELECT EXISTS`).
- A page with records, including this device's own uploads coming back, re-read the whole mirror inside the main actor's synchronous commit. `persistCloudKitPull` now reads only the incoming keys, before any write, so every lookup still sees the mirror as it was before the pull.
- The same commit re-read and hashed the full file of every echoed receipt. A row that already records the same checksum, file size, and uploaded state cannot change (a matching file rewrites identical values, a mismatching one writes nothing), so that case is skipped.
- `CloudKitJournalMerger.applying` rewrote unchanged values and so copied whole arrays. It now leaves equal values alone; an echo-only merge shares storage with the live journal, which makes later identity checks, the SQLite diff, and validation constant time.
- The pass ended by blocking the main actor on the serial writer, then on a scan that decodes every receipt-upload claim ever made (claims are never deleted). The pass now awaits `cloudKitSyncDidFinishAsync`; the claim scan decodes each distinct claim once per process.
- Installing the sync timestamp cleared the validated-journal cache and refreshed the badge and system shortcuts, so the next pass validated the whole journal on the main actor again. The timestamp install is now silent in every respect (`installSyncTimestamp`).
- Validation for a sync flush runs on the writer. Values validated on the main actor for a save, or by the writer for a deferred save, are remembered through a journal revision counter, so a journal is not scanned twice.

**Changes from another device.** Any remote change rebuilt every derived cache on the main actor (12.6 ms for 5,000 and 25.2 ms for 10,000 synthetic transactions in an optimized Mac build, before register invalidation). Up to 64 changed one-off transactions are now applied through the same targeted helpers that local single-row edits use (`refreshDerivedCacheForRemoteTransactionChanges`). Other record families, repeating entries, larger changes, and reordered rows still take the full rebuild.

Verification: `MobileCompanionTests` compares every cached view (all scopes, per-account and per-currency registers, balances, totals, amounts, account flows, search, recurrence anchors) between the targeted update and a store rebuilt from the same journal, checks that the fallbacks still rebuild, and checks that a finished pass stores its timestamp without publishing. `SQLiteCloudKitSyncTests` covers the mirror existence check and the receipt echo conditions. The sync-pass changes were verified for behavior, not timed: that suite's wall time varied between 4 s and 37 s on the same build, so it is not a usable benchmark. Frame pacing on a device was not measured as part of this change.
