# Verification — September 6, 2026

## Completed

- **135 tests passed in one complete run** on iPhone 17 Pro Max / iOS 26.5 with Xcode 26.6 (117 domain/protocol tests and 18 UI flows). After the final cash-flow correction, all 11 focused parity/register tests passed, including two new refund/currency/category tests. Result bundles end in `04-53-13-902Z_pid89554_af645276.xcresult` and `05-02-46-504Z_pid89554_8c2b7ffa.xcresult`.
- The matching Mac recurrence implementation passed all **649 Mac tests**, including its actual store, batch deletion, SQLite reopen, deleted-first-entry month-end cadence and future truncation. TestFlight build **88** completed archiving and internal distribution successfully. Both shared model/editor files are identical between repositories. A signed native Mac build succeeded.
- UI tests create journals/accounts, search/select currencies and nested accounts, verify 22-point hierarchy indentation and the fixed transaction text column, exercise bulk clearing and split-row removal, show the cash-flow chart, save an exact **25.00** transaction, inspect its detail and verify persistence after relaunch. The two account-focused UI cases were rerun successfully after tightening picker sections and hiding empty groups. Screenshots are in `screenshots/` and use synthetic data only.
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

## Not yet established

Real receipt-camera capture and iOS background APNs delivery remain unverified. Foreground APNs and the physical iPhone–Mac Development round trip passed. The installed Mac TestFlight build 86 uses Production CloudKit/APNs and its live Sync screen reports everything up to date. iOS TestFlight processing passed; the external build is Waiting for Review.

The existing Xcode account successfully used Apple cloud-managed distribution signing and provisioned a matching App Store profile. A local distribution private key is not required for this path. The independent App Store Connect record and beta review contact are configured. Build **1.0.0 (2)** uploaded and processed successfully. Build 1 was withdrawn to replace its icon. The requested Gmail tester is verified in Personal Beta, and the build is Waiting for Review with automatic notification enabled. See `testflight-release.json`. GitHub API-key secrets/first CI run and automatic push delivery remain future setup.

The project is an independent local Git repository on `codex/ios-companion`, with no remote or push created by this task. Its initial commit contains the independent app, tests, reference audit and release scripts.

## Final icon revision

Build 2 uses the provided circular coin artwork at full size with white corner areas outside the circle. The former green extension is removed. All 18 assets were checked for exact dimensions, opaque RGB pixels and white corners. The Home Screen was inspected again, the updated signed Development build was installed on the physical iPhone, and normal launch with no QA arguments was confirmed. The app’s functional code is unchanged from the passing test runs.

The checked-in Xcode project also preserves iCloud, Push Notifications and Background Modes as typed capability dictionaries after regeneration. The independent preflight validates these against the target’s actual entitlements.
