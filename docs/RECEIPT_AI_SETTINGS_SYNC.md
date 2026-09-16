# Receipt AI settings sync

Mac, iOS, and web share a single `FinancesRecord` in the private CloudKit zone
`FinancesPreferences_v1`. It is separate from journal and card metadata zones,
so older clients never encounter a new domain record in their journal feed.
The existing CloudKit record schema is reused; no new record fields are needed.

- Domain: `receipt_preferences`
- ID: `00000000-0000-0000-0000-000000000001`
- Payload: `id`, `version: 1`, `model`, `effort`, `instructions`
- Record hash: SHA-256 of the exact UTF-8 payload
- API server URL, authentication, and credentials remain local.

Each client maintains a durable pending edit and the cloud record it was based
on, scoped to container, environment, and iCloud user. Changes are persisted
before upload. CloudKit change tags/system fields provide optimistic concurrency;
unacknowledged writes remain pending. A revision race causes a fresh download
and merge, with bounded retries. An edit made while a save is in flight remains
pending until it receives its own acknowledgment.

The merge uses two logical fields: `(model, effort)` and `instructions`.
Independent changes merge automatically; identical changes do not conflict.
Different edits to the same logical field stop uploads and display both versions.
Choosing this device or iCloud applies only to conflicting fields and preserves
independent changes. A stale conflict choice is rejected. Empty instructions
are an intentional value and can replace an earlier custom prompt.

On first use, existing local preferences seed an absent cloud record. An existing
cloud record wins, even if it contains defaults or empty instructions. Native
legacy settings can seed only the first confirmed iCloud account. Web legacy
preferences are already account-scoped and are retained if the initial download
fails. Pending settings survive restarts and are never transferred to another
account. At least one successful connection is required before editing a new
account's settings; cached accounts can edit offline.

Web refreshes on focus, network restoration, and a foreground timer. Native
clients refresh after journal sync, when receipt settings open, and before receipt
analysis. Both settings screens provide an explicit refresh action and show
pending changes or errors.

Deterministic tests exercise the common payload, independent offline edits,
same-field conflicts, stale resolution, revision retries, restart persistence,
in-flight edits, and account separation. These tests do not establish production
CloudKit delivery or TestFlight availability; those require signed-client and
release verification.
