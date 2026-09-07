# Source provenance

Independent iOS project created September 6, 2026.

- UI reference: Gan Tu’s original FinanceClone iOS project and supplied 100-second recording. No original project files were changed.
- Data model, SQLite storage, CloudKit protocol, recurrence engine, importers and initial mobile services are copied from the FinancesMacApp project in FinancesAppMock. They are vendored here with no external path dependency.
- The shared CloudKit container and zone must remain compatible with the Mac app. This app does not connect to the third-party original Finances app’s private container.
- The iOS live-verification reporter includes synthetic journal validation messages to diagnose physical-device failures. This diagnostic change does not alter the shared wire protocol.

Initial shared file hashes:

```json
{
  "StartupTiming.swift": "ff83291e9e0117824376440d7f71e269dee3ba16c742a1f08859882ed0f565f2",
  "SQLiteImporter.swift": "96c51988673aea90c55331fa5c69f133452e63da5ce4409b7502b006abc4adc5",
  "CloudKitPeerPushVerification.swift": "31d0c130a686edf736caa654bf827871b5ecafb89bb550f4090c44c7f0511176",
  "SQLiteJournalStore.swift": "f51af44df8983f1116eb31de065f219bcba43c483c9494e1e6a3bc30e5943e90",
  "CloudKitSyncService.swift": "e139dd522b33d43579a5b07162e1e67e2c37ba531fcb89bbe50341e55fd59cc8",
  "CloudKitPeerVerification.swift": "5d381b77da0aee4838facbb48c7dfd94991fe1f7738360a553fe866df38d136b",
  "AttachmentDuplicator.swift": "e1f44843c2d269880d7411c2041a2782e328c49e4c31100afd3e9038e25b6539",
  "AmountExpressionEvaluator.swift": "a6212cc60a6a548c3487672691672d5ed323bf02c90d360115cc1879ef700597",
  "BankStatementImporter.swift": "8dc69b10cf539d97ab9f43761db329dd4855610c619c7d2f05c226c627af05cf",
  "UUIDOrdering.swift": "d37d3c29e7c8e9c99fdfb26f9a98e566c332038cc1cb0d1065eed912a9857cff",
  "RecurringTransactionEditPolicy.swift": "04d4e82cb251f69ee9a0a9195b777eeb5d24d82cf75681aca0770e633d0f4fb9",
  "Models.swift": "a80c0de17f757d7d086b1d3163e531ca3dea2f8561bca281ba41b783fcbd2342",
  "NativeJournalStorage.swift": "10c3c2ef25cd9a679a981c4704b7ce8f04cdd9f17730649c6f9a8e4ecd0aee88",
  "RecurringJournalEditor.swift": "bdadd6ff57a959c64155fa2f3f3b654b124f34c1d1bb2a869d30229331b90192",
  "CloudKitJournalSyncCoordinator.swift": "39f1705efce22a14100fe7c7d71a45ef3f6b53042345694ae14bda2a26c06540",
  "CloudKitLiveVerification.swift": "abf59f160cc219c0540c3b9b64474b85318b5aca3c7ed5168940e13918753279",
  "CloudKitForegroundSyncTriggers.swift": "e6b638d3a26c964993e1486ba2d255a1034a665368c093148b49921d90580403"
}
```

The shared Models.swift and RecurringJournalEditor.swift were subsequently updated in both repositories with owner authorization to preserve schedule cadence when deleting the first occurrence. The import hashes above identify the original vendoring snapshot, not the final modified files.
