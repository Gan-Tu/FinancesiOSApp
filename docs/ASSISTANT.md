# Native Finance Assistant

The iPhone owns tool execution, approvals, conversation checkpoints, and financial writes. The existing Finances backend authenticates the current CloudKit user, proxies Responses inference, and creates WebRTC voice sessions. It does not mirror the journal or run unattended finance operations.

## Local testing — mock inference only

Never use real model inference for development, tests, verification, demos, or deployment checks, including against production endpoints. Existing API keys are not permission to make paid test calls.

Debug and Simulator builds block real chat, voice, and receipt inference. Launch the isolated sample app with `--demo` to use `AssistantMockGateway`; no backend, API key, or provider connection is required. Mock history uses the isolated sample scope and must not be mixed into real account history.

```sh
xcrun simctl launch --terminate-running-process <SIMULATOR_UDID> \
  dev.gan.FinancesApp.iOS --demo --mock-ai
```

Existing demo data and mock history survive relaunch. `--reset-demo` resets only the disposable fixture. In Ask AI, “What is my Checking balance in Personal?” exercises the real local read tool with a deterministic mock response. `MOCK_SLOW_REPLY` provides a cancellable mock stream for follow-up tests. Photo uploads are simulated locally, and voice inference is unavailable in development.

Each tap on **Ask AI** opens a fresh conversation with a centered welcome. Existing conversations, including paused work, remain in **History**; select one there to continue or resume. Opening and closing an untouched welcome does not add an empty history entry. Answers render Markdown headings, lists, quotes, links, code, and tables; wide tables and code scroll horizontally inside the message. In **History**, swipe left for **Rename** or **Delete**. Renaming preserves the conversation's activity date and 30-day expiry.

**Settings → Ask AI** and the chat's **Assistant Settings** open the same app-wide preferences. Unset model choices default to `gpt-5.6-terra` with medium reasoning; valid saved overrides are preserved. Model, reasoning, and instructions use a separate private iCloud preferences zone with an account-scoped local outbox. Synced settings restore after reinstalling with the same iCloud account; pending changes must finish syncing first. Sample-mode preferences remain local. Each new request snapshots current preferences; paused work keeps its original settings. Live voice captions are hidden; production voice uses speakerphone noise filtering and conservative speech detection.

A browser mirror can be started with `npx --yes serve-sim@latest <SIMULATOR_UDID>`. Use the URL it prints; do not expose it on the network unless explicitly needed. On Xcode 27, native Simulator windows are managed through Device Hub.

## Verification

```sh
scripts/test.sh --smoke
scripts/test.sh -only-testing:FinancesiOSTests/AssistantTests
scripts/test.sh -only-testing:FinancesiOSTests/AssistantMarkdownTests
scripts/test-assistant-local.sh
ASSISTANT_UI_TEST=AssistantInteractionTests/testLocalHistorySwipeRenamePersists scripts/test-assistant-local.sh
```

The local UI command enables only deterministic mock tests, including streaming cancellation, tool execution, attachments, and termination/relaunch history recovery. It clears `OPENAI_API_KEY`, sets `FINANCES_DISABLE_INFERENCE=1`, and does not start or contact a backend. Select a Simulator with `ASSISTANT_SIMULATOR=<UDID>`. Normal CI/full-suite runs skip these optional UI scenarios; the release smoke selection stays small.

The web repository also provides:

```sh
node --import tsx scripts/export-native-assistant.ts --check ../FinancesiOS/App/AssistantContract.json
npm run check:server
npm run test:server
npm run build
```

## Contracts and recovery

- Protocol version 1 uses `mobile-assistant/options`, `mobile-assistant/step`, and `mobile-assistant/voice-session` under `/api/v1/`. Swift sees app-owned messages, tool calls/results, citations, and opaque user-signed continuation data, not SDK types.
- The bundled 44-tool contract is exported from the canonical web catalog. Native finance commands reuse `MobileLedgerStore` operations and exact decimal strings.
- Hosted tool search defers finance and conversation-title tools; only app context is eager. Discovery state stays in signed continuations, and discovery-only steps continue inference before local actions execute.
- SQLite `assistant_actions` commits action results in the same transaction as ledger/outbox changes. It is the authority after a lost reply. `assistant_history` contains local-only 30-day checkpoints. Neither table is part of CloudKit envelopes or portable finance backups.
- Pending intents must be durable before execution. Resume rechecks identity, current record revisions, and approval fingerprints. Cancel Remaining reconciles committed receipts before marking unfinished calls cancelled.
- Pausing stops new execution. Already-started atomic commits finish or roll back. A stopped run never implies an undo.
- Local identity verification precedes showing history. Gateway failure does not hide already verified local history. Account changes cancel and hide account-specific state.
- GPT-Live client delegation is preferred. Explicit delegation events, timestamped user/assistant transcripts, and request IDs own voice tasks. Realtime uses the same native agent through `run_finance_task` if Live access is unavailable. Voice results are never reassigned to a newer request.
- Temporary uploads are separate from saved receipts. Expired chat uploads can be removed from historical inference context without deleting journal attachments or replaying saved edits.

## Validation limits

Simulator tests do not establish physical-device microphone, Bluetooth/AirPods, real iCloud account switching, or cross-device CloudKit delivery. Use synthetic recordings and local fixtures for hardware verification. Never invoke a real model for those checks. Latency targets are goals; the code records tool duration and does not claim measured production latency.

Production use requires deploying the compatible backend routes. Standard API keys remain server-side; `store:false` and disabled tracing do not promise zero provider retention.
