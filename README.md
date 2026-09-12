# Finances v2 for iOS

An independent SwiftUI iPhone and iPad companion to Gan Tu’s CloudKit-enabled Finances Mac app. Requires iOS 17 or later; builds with Xcode 26.6. This repository contains every source file it needs. The original FinanceClone project is unchanged. The Mac companion received the matching, owner-authorized recurrence update so either device can delete one occurrence without changing the remaining schedule.

Open **FinancesiOS.xcodeproj** and select **FinancesiOS**. Choose a simulator and Run. A fresh installation starts with an empty journal list. Create a journal or enable iCloud Sync on a signed device to join the Mac’s journals.

## Features

- Journals with Personal/Business account templates, rename, delete and reordering.
- Nested accounts with ordering and grouping, account and currency registers, search, monthly income/expense summaries, account breakdown and cash-flow charts.
- Expenses, income, transfers, split postings, arithmetic amount entry, cleared status, transaction duplication and reusable templates.
- Repeating schedules, occurrence/future edit scopes, attachments, searchable account selection and journal-specific currencies.
- Receipt file/photo import, on-device receipt scanning, inline thumbnails and Quick Look previews.
- Local SQLite persistence, ZIP backup/restore with receipt files, native sharing, display preferences and password lock.
- Shared CloudKit private database, receipt assets, offline changes, explicit conflicts, account-change handling and automatic foreground/push sync.
- Configurable Home Screen template actions, Siri/App Shortcuts, receipt Open In, and a local Apple Pay Suggestions inbox with editable drafts.
- Refund/reimbursement tracking with partial-payment links, outstanding amounts, and backup/sync preservation without changing monetary postings.

See [Quick entry and refund tracking](docs/QUICK_ENTRY.md) for setup, Wallet automation, and receipt sharing.

The app uses the Mac project’s `iCloud.dev.gan.FinanceApp` container and `FinancesJournal_v1` zone. Use the same Apple Account and CloudKit environment on each device. Simulator builds are intentionally offline; a successful simulator test is not evidence of physical device synchronization.

## Backups

Export Backup streams all journals and receipt files into a ZIP, then opens Apple's share sheet for Files and installed destinations such as Dropbox. Preparation belongs to the app rather than the screen, and a completed export remains available under Share Prepared Backup. iOS 26 uses continued processing when available; older systems use Apple's finite background allowance. If the system stops preparation, the app discards the incomplete file and leaves the journal unchanged.

Import Backup accepts these ZIPs, wrapped Mac `.fin` ZIPs, `.fin` directories and older mobile backup files. It validates and stages the full backup before replacing the current journals after confirmation. Cloud Sync is disabled after restore. Restored repeating series continue generating future entries from their saved rules and continuation cursor, without recreating covered/deleted slots. See [recurrence backup compatibility](docs/BACKUP_CONTINUATION.md) for older-format behavior. Large older JSON backups should first be converted to ZIP on a device that can open them; mobile legacy JSON import is bounded to avoid running out of memory.

Registers open near today with future entries reachable above. An enabled chart stays visible on return. The bottom Search button searches the current register without expanding or collapsing the navigation bar.

## Build and test

```sh
scripts/test.sh
scripts/archive.sh CODE_SIGNING_ALLOWED=NO
```

The second command verifies a Release archive without uploading or producing a distributable signature. Build/test outputs stay in ignored `build/`. Set `SIMULATOR_DESTINATION` to override the default iPhone 17 Pro Max.

For a local demonstration, add `--demo --reset-demo` to the scheme’s launch arguments. This creates synthetic data in a separate temporary directory and blocks CloudKit. Remove both arguments for normal use. The demo code is excluded from Release.

`project.yml` is the reproducible XcodeGen definition. After changing targets or files, run `xcodegen generate` and include the generated project in your change. XcodeGen is not required just to build the committed Xcode project.

## Distribution

Source lives at [Gan-Tu/FinancesiOSApp](https://github.com/Gan-Tu/FinancesiOSApp). Every push to `main` starts the **Finances v2 iOS Release** Xcode Cloud workflow: required iPhone tests, a signed archive, and delivery to the **Internal Testing** group. GitHub Actions also runs tests on pushes and pull requests. See [Release Setup](docs/RELEASE.md) for the workflow and tester details.

See [UI reference and parity](docs/UI_REFERENCE.md), [CloudKit compatibility](docs/CLOUDKIT.md), [verification](docs/VERIFICATION.md), and [source provenance](docs/SOURCE_PROVENANCE.md).
