# Release setup

The app displays **Finances v2** on iPhone and iPad. Its separate App Store Connect listing is **Finances v2 for iOS** (Apple ID **6809320145**); Apple reserves the exact Finances v2 listing name for the existing Mac app. The iOS bundle ID remains **dev.gan.FinancesApp.iOS**, under team **K3URZZFDQP**. Version is **1.0.0**.

## Automatic releases

The independent repository is [Gan-Tu/FinancesiOSApp](https://github.com/Gan-Tu/FinancesiOSApp), with `main` as the release branch. Xcode Cloud workflow **Finances v2 iOS Release** (`DF223336-1A31-46E0-AD46-553F136D2EA9`) is enabled with:

- Primary repository `https://github.com/Gan-Tu/FinancesiOSApp.git` and project `FinancesiOS.xcodeproj`.
- Branch Changes on `main`, triggered by any changed file; superseded runs may be canceled.
- Required iPhone tests using scheme `FinancesiOS`.
- An iOS archive prepared for App Store Connect, using Apple-managed signing.
- TestFlight Internal Testing delivery to **Internal Testing** (`dab76ac6-fee0-4017-9348-8287ff48c3b9`).

The iOS Cloud product is **DD1BB18D-ED95-4E32-A428-D109B0906D51**, separate from the Mac product **F6360E5A-E7BB-48AF-AABB-DB45113C1F15**. The new iOS counter starts at **100**, above its last uploaded build91. Do not reset it to the local project build number. The former iOS workflow `C33DA8C1-4329-46D0-AABA-2EA88BF8D3F1` under the Mac product is disabled after build100 successfully completed tests, archive and internal distribution. Mac workflows/history are preserved.

The owner-requested Hotmail tester was invited to Internal Testing and build **1.0.0 (100)** was assigned. The Gmail tester remains in external **Personal Beta**; build100 replaced build3 in Apple's beta-review queue with automatic notification enabled. Internal builds do not require that external review. Accept the TestFlight invitation with the corresponding Apple Account.

GitHub Actions independently builds and tests pushes and pull requests. Xcode Cloud performs release signing and upload; no GitHub signing secrets or App Store Connect API key are required. The obsolete manual GitHub upload workflow has been removed. `TestFlight/WhatToTest.en-US.txt` supplies testing guidance for future Cloud releases.

## CloudKit and signing

Both released apps use the user's private `iCloud.dev.gan.FinanceApp` container, Production environment and `FinancesJournal_v1` zone. Debug builds use Development and a separate local store. Use the production **Finances v2.app** on Mac when comparing with TestFlight; isolated QA apps intentionally have different data. Read-only Production data comparison passed; see `production-sync-verification.json`.

The project includes CloudKit/APNs entitlements, background notifications, privacy manifest, usage descriptions, an opaque app icon and a shared test/archive scheme. Apple-managed signing and App Store IPA export have passed. No private signing key is stored in this repository.

## Local archive

Open `FinancesiOS.xcodeproj`, select the FinancesiOS scheme and Any iOS Device, then Product → Archive. Alternatively run:

```sh
scripts/archive.sh -allowProvisioningUpdates
scripts/export_app_store.sh -allowProvisioningUpdates
```

`scripts/upload_testflight.sh -allowProvisioningUpdates` uploads a local archive using the existing Xcode account. Choose a new unique build number before a manual release. Apple processing and external beta review are separate from successful upload. See `VERIFICATION.md` and `testflight-release.json` for release evidence.
