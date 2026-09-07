# Mac and iOS CloudKit compatibility

| Setting | Value |
| --- | --- |
| Apple team | `K3URZZFDQP` |
| iOS bundle ID | `dev.gan.FinancesApp.iOS` |
| Companion Mac bundle ID | `dev.gan.FinancesMacApp` |
| Container | `iCloud.dev.gan.FinanceApp` |
| Database | Current user’s private database |
| Zone | `FinancesJournal_v1` |
| Debug environment | Development |
| Release/TestFlight environment | Production |

`Core/` vendors the Mac’s data models, SQLite storage, CloudKit transport/coordinator, recurrence and backup/import code. Record identities, JSON field names, receipts and conflict behavior remain compatible with the Mac. There is no source-path dependency on its checkout. The earlier Cloudflare-based mock and the third-party original Finances app do not use this CloudKit protocol.

A new device starts with no records and downloads before uploading. Local edits queue in SQLite while offline. The coordinator handles paginated downloads, asset hashes, stale responses, account changes, interrupted uploads, push/foreground/reconnect triggers, and explicit competing-edit resolution. App preferences and local unlock state are not treated as shared financial records.

The development schema is provided at `CloudKit/FinancesPrivate.ckdb`. Verify it against the existing container rather than creating a second incompatible schema. Production schema deployment and TestFlight validation are separate from Development tests. Apple documents [schema deployment](https://developer.apple.com/documentation/CloudKit/deploying-an-icloud-container-s-schema) and [container environments](https://developer.apple.com/documentation/cloudkit/ckcontainer).

## Device acceptance

1. Use signed Debug builds of both apps on the same Apple Account. Start with a synthetic journal.
2. Enable iCloud on the Mac, then the iPhone. Confirm the same journal/accounts and transaction UUIDs arrive.
3. Create an iPhone transaction and attach a synthetic receipt. Confirm amount, posting accounts, cleared state and receipt bytes on the Mac.
4. Edit the entry offline on the iPhone, reconnect, and verify convergence after returning to the app.
5. Create conflicting edits and use the explicit conflict picker. Delete an occurrence and confirm it stays deleted after relaunch and sync.
6. Repeat with Release builds after the schema exists in Production. Development data does not migrate automatically to Production.

The repository’s fake-transport tests exercise storage and protocol behavior without accessing personal data. Physical iOS round-trip and background notification delivery must be verified separately; do not infer them from a build or local sync counter.

## Physical Development evidence

The signed iOS app was installed and launched on a physical iPhone 17 Pro Max (iOS 27.0). The signed Mac app and iPhone completed the staged producer/consumer round trip in a run-specific Development zone. Foreground APNs, automatic download and upload, receipt bytes and a recurring one-off edit matched on Mac readback. The producer removed its owned QA zone and verified absence.

`physical-sync-verification.json` matches the independently executed device/Mac reports; the reports themselves deliberately do not infer physical provenance from random instance IDs. `device-live-verification.json` records all 11 real-service scenarios on the iPhone, including conflicts, offline editing, deletion and restart. Neither entry point opened the normal journal. Background push and Production/TestFlight checks remain separate.

## Current Production and recurrence compatibility

On September 6, 2026, the installed Mac TestFlight build 86 was independently checked: its signed entitlements select Production CloudKit/APNs, and its Sync screen reports “Everything is up to date.” The Mac repository records the schema deployment after build 80. The iOS build uses the same record schema and container; its external TestFlight review is pending.

Both clients now preserve the original schedule anchor inside recurrence template-history JSON when the first occurrence is deleted. This requires the matching Mac change, commit `847ecaa`, which was pushed to its existing release branch. Older Mac versions may discard the optional metadata during edits. Use the updated Mac companion when testing first-occurrence deletion across devices. No CloudKit schema-field migration is required.
