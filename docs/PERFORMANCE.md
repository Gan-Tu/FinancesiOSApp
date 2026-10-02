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

Verification: `AssistantTests` asserts that appending to the draft publishes the draft object only, never the coordinator. Device frame pacing while typing and streaming was not measured as part of this change.
