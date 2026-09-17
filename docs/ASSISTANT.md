# Native Finance Assistant

The iPhone owns tool execution, approvals, conversation checkpoints, and financial writes. The existing Finances backend authenticates the current CloudKit user, proxies Responses inference, and creates WebRTC voice sessions. It does not mirror the journal or run unattended finance operations.

## Local testing

The current isolated Simulator is named **Finances Assistant**. It uses the sample ledger and a loopback backend, with CloudKit disabled for that fixture. No changes need to be committed or deployed.

Start the backend in the sibling `FinancesWeb` checkout using Node 22.12 or newer:

```sh
node scripts/dev-ios-assistant.mjs
```

It listens on `http://127.0.0.1:5184`, reuses the ignored `.env.local` OpenAI key, and stores temporary test uploads in `.local/assist/chat-files`. That file storage is explicitly gated by local development mode and is unavailable in production. Keep the terminal running.

Build/install the iOS app and launch the selected Simulator with:

```sh
xcrun simctl launch --terminate-running-process <SIMULATOR_UDID> \
  dev.gan.FinancesApp.iOS --demo --assistant-api-url http://127.0.0.1:5184
```

The endpoint override is accepted only in Debug, with `--demo`, and only for loopback hosts. Existing demo data and assistant history survive relaunch. `--reset-demo` intentionally resets the disposable fixture.

Tap **Ask AI** in the center of the global bottom bar to open **Ask Finances**. Sync status sits beneath the navigation title; tapping the title opens sync options. After the data-use disclosure, try:

- “What is my Checking balance in Personal?”
- “Find the sample grocery receipt and explain it.”
- “Record a $12 lunch from Checking to Groceries today.” Review the resulting record, then test a delete request's confirmation preview.
- Start a longer request, leave the app, reopen it, and tap **Resume**. Completed edits must remain single entries.
- Tap Voice, grant microphone access when you want to speak, and test a spoken correction. Ending voice or leaving the app stops capture and playback.

Each tap on **Ask AI** opens a fresh conversation with a centered welcome. Existing conversations, including paused work, remain in **History**; select one there to continue or resume. Opening and closing an untouched welcome does not add an empty history entry. Answers render Markdown headings, lists, quotes, links, code, and tables; wide tables and code scroll horizontally inside the message. In **History**, swipe left for **Rename** or **Delete**. Renaming preserves the conversation's activity date and 30-day expiry.

**Settings → Ask AI** and the chat's **Assistant Settings** open the same app-wide preferences. Model, reasoning, and instructions use a separate private iCloud preferences zone with an account-scoped local outbox. Synced settings restore after reinstalling with the same iCloud account; pending changes must finish syncing first. Sample-mode preferences remain local. Each new request snapshots current preferences; paused work keeps its original settings. Live voice captions are hidden; provider interruption sensitivity stays at its default.

A browser mirror can be started with `npx --yes serve-sim@latest <SIMULATOR_UDID>`. Use the URL it prints; do not expose it on the network unless explicitly needed. On Xcode 27, native Simulator windows are managed through Device Hub.

## Verification

```sh
scripts/test.sh --smoke
scripts/test.sh -only-testing:FinancesiOSTests/AssistantTests
scripts/test.sh -only-testing:FinancesiOSTests/AssistantMarkdownTests
scripts/test-assistant-local.sh
ASSISTANT_UI_TEST=AssistantInteractionTests/testLocalHistorySwipeRenamePersists scripts/test-assistant-local.sh
```

The default local UI command explicitly enables a paid, synthetic-data live round-trip against the local backend, including termination/relaunch history recovery. The history variant checks the welcome screen and rename/delete interactions without sending an inference request. Both select the Simulator named Finances Assistant, or accept `ASSISTANT_SIMULATOR=<UDID>`. Normal CI/full-suite runs skip these local UI tests. The normal release smoke selection is unchanged.

The web repository also provides:

```sh
node --import tsx scripts/export-native-assistant.ts --check ../FinancesiOS/App/AssistantContract.json
npm run check:server
npm run test:server
npm run build
```

## Contracts and recovery

- Protocol version 1 uses `mobile-assistant/options`, `mobile-assistant/step`, and `mobile-assistant/voice-session` under `/api/v1/`. Swift sees app-owned messages, tool calls/results, citations, and opaque user-signed continuation data, not SDK types.
- The bundled 42-tool contract is exported from the canonical web catalog. Native finance commands reuse `MobileLedgerStore` operations and exact decimal strings.
- Hosted tool search defers 41 finance tools in eight namespaces; only app context is eager. Discovery state stays in signed continuations, and discovery-only steps continue inference before local actions execute.
- SQLite `assistant_actions` commits action results in the same transaction as ledger/outbox changes. It is the authority after a lost reply. `assistant_history` contains local-only 30-day checkpoints. Neither table is part of CloudKit envelopes or portable finance backups.
- Pending intents must be durable before execution. Resume rechecks identity, current record revisions, and approval fingerprints. Cancel Remaining reconciles committed receipts before marking unfinished calls cancelled.
- Pausing stops new execution. Already-started atomic commits finish or roll back. A stopped run never implies an undo.
- Local identity verification precedes showing history. Gateway failure does not hide already verified local history. Account changes cancel and hide account-specific state.
- GPT-Live client delegation is preferred. Explicit delegation events, timestamped user/assistant transcripts, and request IDs own voice tasks. Realtime uses the same native agent through `run_finance_task` if Live access is unavailable. Voice results are never reassigned to a newer request.
- Temporary uploads are separate from saved receipts. Expired chat uploads can be removed from historical inference context without deleting journal attachments or replaying saved edits.

## Validation limits

Simulator tests do not establish physical-device microphone, Bluetooth/AirPods, real iCloud account switching, or cross-device CloudKit delivery. Validate those on signed devices before release. Latency targets are goals; the code records tool duration and does not claim measured production latency.

Production use requires deploying the compatible backend routes. Standard API keys remain server-side; `store:false` and disabled tracing do not promise zero provider retention.
