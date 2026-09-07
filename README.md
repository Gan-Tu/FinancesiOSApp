# Finances v2 for iOS

An independent SwiftUI iPhone and iPad companion to Gan Tu’s CloudKit-enabled Finances Mac app. Requires iOS 17 or later; builds with Xcode 26.6. This repository contains every source file it needs. The original FinanceClone project is unchanged. The Mac companion received the matching, owner-authorized recurrence update so either device can delete one occurrence without changing the remaining schedule.

Open **FinancesiOS.xcodeproj** and select **FinancesiOS**. Choose a simulator and Run. A fresh installation starts with an empty journal list. Create a journal or enable iCloud Sync on a signed device to join the Mac’s journals.

## Features

- Journals with Personal/Business account templates, rename, delete and reordering.
- Nested accounts with ordering and grouping, account and currency registers, search, monthly income/expense summaries, account breakdown and cash-flow charts.
- Expenses, income, transfers, split postings, arithmetic amount entry, cleared status, transaction duplication and reusable templates.
- Repeating schedules, occurrence/future edit scopes, attachments, searchable account selection and journal-specific currencies.
- Receipt file/photo import, on-device receipt scanning, inline thumbnails and Quick Look previews.
- Local SQLite persistence, backup/restore, bank-statement import, display preferences and password lock.
- Shared CloudKit private database, receipt assets, offline changes, explicit conflicts, account-change handling and automatic foreground/push sync.

The app uses the Mac project’s `iCloud.dev.gan.FinanceApp` container and `FinancesJournal_v1` zone. Use the same Apple Account and CloudKit environment on each device. Simulator builds are intentionally offline; a successful simulator test is not evidence of physical device synchronization.

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
