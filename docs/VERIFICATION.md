# Verification — September 6, 2026

## Completed

- **135 tests passed in one complete run** on iPhone 17 Pro Max / iOS 26.5 with Xcode 26.6 (117 domain/protocol tests and 18 UI flows). After the final cash-flow correction, all 11 focused parity/register tests passed, including two new refund/currency/category tests. Result bundles end in `04-53-13-902Z_pid89554_af645276.xcresult` and `05-02-46-504Z_pid89554_8c2b7ffa.xcresult`.
- The matching Mac recurrence implementation passed all **649 Mac tests**, including its actual store, batch deletion, SQLite reopen, deleted-first-entry month-end cadence and future truncation. TestFlight build **88** completed archiving and internal distribution successfully. Both shared model/editor files are identical between repositories. A signed native Mac build succeeded.
- UI tests create journals/accounts, search/select currencies and nested accounts, verify 22-point hierarchy indentation and the fixed transaction text column, exercise per-entry clearing and split-row removal, show the cash-flow chart, save an exact **25.00** transaction, inspect its detail and verify persistence after relaunch. The two account-focused UI cases were rerun successfully after tightening picker sections and hiding empty groups. Screenshots are in `screenshots/` and use synthetic data only.
- Regression tests cover Decimal precision/arithmetic, account-context drafts, journal reordering, zero starting balances, durable save/edit/clear/delete, receipt backup/reopen, separate currency totals and search-independent running balances.
- Shared storage/CloudKit/recurrence tests cover pagination, cancellation, conflicts, tombstones, asset bytes, interrupted writes and schedule editing.
- Physical-device regression fixes cover canonical receipt paths before/after deletion, durable deletion tombstones, current balances excluding future entries, and register landing near today. The Cloud Sync sheet matches the supplied reference and has separate help/conflict review.
- **Physical iPhone–Mac round trip passed** using the signed native apps and real Development CloudKit. The iPhone received a matching APNs notification while foregrounded, automatically converged, edited the transaction/recurrence and receipt, and automatically uploaded its reply. The Mac verified matching challenge, amount, transaction and receipt digests. The isolated QA zone was removed and verified absent. See `physical-sync-verification.json`.
- **All 11 live-device scenarios passed** on iPhone 17 Pro Max / iOS 27.0, covering initial download, offline edits, receipts, explicit conflicts, deletion, restart, accepted-request cancellation, recurrence edits and tombstones. See `device-live-verification.json`. The normal app was relaunched afterward without QA arguments.
- A test with **two actual MobileLedgerStore instances** passed receipt transfer, an offline edit, deletion and reopen through the shared CloudKit protocol using an in-process fake server. No Apple service or personal records were accessed by these tests.
- All 18 green app-icon files have exact asset dimensions and no alpha. The installed green icon was also visually verified on the simulator Home Screen. Currency rows were visually checked: only the selected name/checkmark is blue.
- App built, launched and visually inspected on iPhone and iPad Pro 11-inch (M5) simulators. iPad validation covered the account, currency, transaction and recurrence form flows; the complete suite ran on iPhone.
- **Signed iOS Development build succeeded.** Its signature independently passed `codesign --verify --deep --strict`. Readback confirmed team `K3URZZFDQP`, bundle `dev.gan.FinancesApp.iOS`, container `iCloud.dev.gan.FinanceApp`, Development CloudKit and development APNs entitlements.
- The installed matching development provisioning profile includes the correct iOS identifier/container and expires September 5, 2027. Existing signing was reused; no credentials were generated.
- **Signed Release archive and App Store IPA export succeeded** for generic iOS. The exported signature passed strict verification, uses the Production container/APNs environment, and has `get-task-allow = false` with an App Store provisioning profile. It contains the app icon and privacy manifest, requires iOS 17+, supports iPhone/iPad and selects the Production CloudKit environment.
- Repository preflight and shell/plist/workflow syntax validation passed. The generated project has no paths back to the source checkouts.
- All **64 original FinanceClone project files** were rehashed and remained unchanged. The owner-authorized matching Mac recurrence patch is in the native Mac repository; unrelated Mac work is preserved.

## Local build outputs

- `build/FinancesiOS-Development.app` — signed development device build; not a TestFlight package.
- `build/FinancesiOS.xcarchive` — signed Release archive.
- `build/export/FinancesiOS.ipa` — App Store-signed package, exported locally without upload.

The build directory is ignored by Git. No financial database, recording, personal receipt or signing private key is part of the repository sources.

## Remaining verification

Real receipt-camera capture remains unverified. Physical foreground and background APNs delivery/convergence passed, with automatic return upload after foreground activation and verified QA-zone cleanup. See `physical-sync-verification.json` and `background-sync-verification.json`.

Build **1.0.0 (3)** is assigned to Internal Testing, with the requested Hotmail tester invited. External Personal Beta is waiting for Apple review. Source is on `main` at `Gan-Tu/FinancesiOSApp`; its first GitHub build/test run succeeded. Xcode Cloud build **90** was triggered by the push of `3c8b87b` and completed required tests, the signed archive and internal TestFlight distribution. The independent GitHub check run `34096886257` also succeeded.

## Final icon revision

Build 2 uses the provided circular coin artwork at full size with white corner areas outside the circle. The former green extension is removed. All 18 assets were checked for exact dimensions, opaque RGB pixels and white corners. The Home Screen was inspected again, the updated signed Development build was installed on the physical iPhone, and normal launch with no QA arguments was confirmed. This icon-only revision did not change functional code.

The checked-in Xcode project also preserves iCloud, Push Notifications and Background Modes as typed capability dictionaries after regeneration. The independent preflight validates these against the target’s actual entitlements.

## Build 3 follow-up

Template accounts now precede the details. Selecting a template with Scan Invoice enabled requests the native receipt scanner; the template form flow and scanner request UI tests passed. The app icon now matches the latest reference: a full green square and white dollar symbol, without a circle, white corners, label or badge. Build 3 uploaded and was submitted for external review. Installation on the physical phone succeeded; automatic launch was blocked by the phone’s lock, so the user can open it normally after unlocking.

## September 7 management and Production checks

- Removed register Edit/selection/batch clear functionality and its obsolete preference state/test.
- Templates opens in management mode, with delete and reorder controls and + at top right. Row taps edit a template; transaction creation remains in the compose menu. Customize Templates presents a Done/+ modal.
- All five targeted register, template and layout UI checks passed in result bundle `test_sim_2026-09-07T07-23-30-813Z_pid89554_a38aa6ff.xcresult`.
- A read-only comparison of the physical iPhone Production store snapshot and running production Mac store found identical journals, accounts, currencies, transactions, postings and templates. See `production-sync-verification.json`. The isolated Mac QA app was the apparent source of the data mismatch.
- Phone display name is Finances v2. The separate Apple listing is Finances v2 for iOS because the Mac listing already reserves the shorter name.

## Completion recheck before independent review

The requested register, swipe, details, form, account hierarchy, currency selection, template order and template management changes were checked against their implementation and regression coverage. Customize Templates was also manually opened in the simulator: Done is on the left, + on the right, and delete/reorder controls remain visible; creating and saving a template from the modal passed. The 64 original FinanceClone file hashes still match the initial snapshot. App display name is Finances v2, with the latest green square icon.

This recheck does not claim actual camera capture was tested or that Apple has approved external beta review. Physical foreground/background CloudKit checks and read-only Production parity are documented separately.

## Independent review release

Four independent review passes ended with no actionable findings at `839d7fd`. All131 domain/storage tests passed after the final receipt-reference fix; the preceding complete suite passed148 with one explicitly opt-in physical-device test skipped. See `INDEPENDENT_REVIEW.md` for findings, fixes and evidence. Original FinanceClone files remain unchanged.

The iOS Cloud product is now separate from Mac: `DD1BB18D-ED95-4E32-A428-D109B0906D51`, workflow `DF223336-1A31-46E0-AD46-553F136D2EA9`. Its first reviewed release is configured as build100. Production CloudKit container, zone and account binding are unchanged. The earlier one-journal Production parity snapshot predates the separate Mac task's authorized full-data seed and is historical evidence, not a claim about current journal counts.


## September 7 backup and stable register follow-up

The complete iPhone 17 Pro Max / iOS 26.5 suite passed **175 tests**, with only the opt-in physical sync test skipped (`test_sim_2026-09-07T20-29-20-258Z_pid18930_238f2c08.xcresult`). Subsequent focused checks verified chart persistence, constant chart position/height through a forced two-second load, numeric search in the bottom sheet, and returning from a search result to the register. The search test initially matched an underlying register row; restricting its query to identified search results fixed the test without weakening the result check.

Backup coverage includes ZIP metadata/receipt round trips, Mac package ZIPs, legacy mobile backups, corrupt/missing/invalid input, duplicate IDs, cancellation and atomic failure cleanup. A 192 MiB receipt round trip kept peak process RSS growth below the 96 MiB regression ceiling; the isolated run measured approximately 2.6 MB growth. New exports stream receipt bytes in 256 KiB buffers.

Native verification exported the demo journal through Apple's share sheet into On My iPhone, selected that ZIP in the Files import picker, confirmed restore, and checked restored journal/transaction/receipt counts. A separate **2 GiB synthetic receipt** export continued writing after the Home action: 28 observed file growth events occurred afterward, and the finished ZIP passed a complete CRC check. This simulator used the finite UIApplication background lease; physical iOS 26 continued-processing scheduling and a Dropbox upload were not independently exercised.

A new 30 fps recording of journal/register entry, chart toggling, return and re-entry showed today's rows appearing directly in position. The chart remained visible on re-entry with a fixed loading/loaded frame. The register no longer installs an automatic search drawer. Search remains available through the bottom magnifying glass with the current register scope. The Journals list now leaves a 16-point top content margin, and account expansion/chart changes respect Reduce Motion.

The final shared recurrence contract passed **153 domain/storage tests** in `test_sim_2026-09-07T20-50-22-092Z_pid18930_dcc3a514.xcresult`. A new regression first reproduced a deleted middle occurrence reappearing after ZIP restore. Restore now marks existing recurrence rules as authoritative because backup payloads do not include tombstones. Direct SQLite reload preserves this optional flag; ordinary edits keep it, while new or explicitly rescheduled rules generate normally. First- and middle-occurrence deletion, restore/reopen, detail edits and creation of a new repeating series all passed. This uses the matching Mac optional rule/ledger provenance fields without changing iOS restore into Mac's import-as-new-journal operation.

The final unsigned iOS Release archive succeeded after the recurrence fix. Project/CloudKit capability preflight and whitespace checks passed. Only synthetic data was used for this backup/navigation verification.


## September 7 Quick Search dates and field filters

Quick Search shows Note, Number, Payee and Anywhere suggestions for typed text, dates under each result amount, and transaction/date shortcuts before typing. A suggestion opens a fully filtered register in the same journal/account/currency scope; its month summary uses the same matching IDs. Quick previews stop at 40 rows while full registers include all matches. Search uses the background renderer, and the unused old global-result cache/trigram index was removed. Ordinary unfiltered registers avoid allocating search strings. Last Month now selects the previous calendar month and excludes current/future dates.

All 155 model/storage tests passed after the changes (`test_sim_2026-09-07T21-35-38-985Z_pid18930_e97424a3.xcresult`). Focused UI tests verified empty shortcuts, dated previews, field actions, preserved queries, no-results behavior, and return navigation. Native screenshots of both popup states were reviewed against the supplied examples.


## Recurring schedules continue after backup restore

This supersedes the earlier frozen-snapshot workaround. Backups carry the schedule anchor/calendar, generation cursor and consumed count alongside recurrence settings and future-template history. Restore preserves the covered range and resumes generation after it. Deleted first/middle/last and moved occurrences remain covered. The same state works after Mac import assigns fresh identities. Native duplication starts a fresh cursor for the new series.

All 160 iOS model/storage tests passed in `test_sim_2026-09-07T23-22-53-445Z_pid18930_7d7ddfd1.xcresult`, including repeated real ZIP export/import and projection beyond the saved horizon. The iOS Release archive passed. The isolated Mac selection executed 183 tests with no failures and one opt-in large-file test skipped, covering full ZIP restore/re-export, new-journal import, native reload, recurrence editing/deletion/duplication, SQLite and CloudKit wire compatibility. See [backup continuation](BACKUP_CONTINUATION.md) for the legacy-file boundary.
