# Quick entry and refund tracking

## Home Screen quick actions

Touch and hold the Finances v2 icon to open a new transaction from a template. Settings → Quick Entry & Shortcuts → Home Screen Quick Actions lets you choose and reorder up to four included templates across visible journals. The first available templates are selected initially; removing every shortcut keeps the menu empty. Hidden journals and excluded or deleted templates are never offered.

Quick actions open editable drafts. A template with missing accounts uses the existing account-first selection flow. Incoming actions wait while the app is locked or another editor is open.

## Siri, Shortcuts, Action button and Control Center

Find these actions under Finances in Shortcuts:

- New Transaction: optional journal, amount with currency, payee, and notes; opens an editable draft.
- Use Transaction Template: selects an included template and opens its editor.
- Open Suggestions: opens pending Wallet captures.
- New Transaction with Receipts: accepts image/PDF files and opens a transaction with those receipts.
- Add Apple Pay to Suggestions: captures a purchase for later review without posting it.

The open actions can be assigned using the system's Shortcuts Action button and Control Center options. App Shortcuts include “Log an expense in Finances v2” and “Use a template in Finances v2.”

## Receipt sharing

Share/Open In an image or PDF and choose Finances. The app copies the receipt into a pending local batch, then opens New Transaction with a journal picker. If another editor or the app lock is active, the batch waits without replacing that editor. Cancel removes that batch; Save uses the normal durable transaction and attachment pipeline.

Some sharing apps provide raw image data rather than an Open In file. For those apps, create a Shortcut with New Transaction with Receipts, connect Receipts to Shortcut Input, and enable Show in Share Sheet for images/PDFs. This uses the same editable transaction flow, without an unsupported Share-extension app-launch workaround.

Pending receipt batches survive an interrupted launch. After a successful save, their stable identity prevents another copy if the app exits before cleanup.

## Apple Pay Suggestions

Create a personal Wallet/Transaction automation in Shortcuts, select your tapped card, and add Add Apple Pay to Suggestions. Connect Amount (including currency), Merchant, and optionally Card Name and Date; choose a journal if desired. Run Immediately captures the supported Wallet event without opening the ledger. The app cannot create this personal automation for you or read a card's complete history.

Check your first capture's currency. If the trigger supplies only a number, explicitly configure Currency Code in the action. No exchange rate is guessed. An unknown card requires account selection; changing journals resets the draft's accounts. A journal without the captured currency cannot save it as a different currency accidentally.

Suggestions are local pending drafts on this device and are not posted balances, iCloud records, or part of a journal backup. Open Suggestions from Journals or Settings, edit, and Save; Cancel keeps the suggestion for later. Dismiss removes a suggestion. Stable capture IDs prevent duplicate conversion after a save/relaunch.

## Refunds and reimbursements

Open a purchase → Refund or Reimbursement. Choose the type, expected amount/currency, person or merchant, optional note and expected date, then Start Tracking. Link existing received transactions and assign the amount belonging to the purchase. Partial payments reduce the outstanding amount; allocations cannot exceed the incoming payment or expected amount. Future payments, transfers with no incoming net amount, and mismatched currencies do not count as received payments.

Journal → Refunds & Reimbursements lists tracked purchases, outstanding amounts and records needing attention. Unlinking, stopping, or removing tracking never changes monetary postings or cleared status. Invalid/deleted links need attention instead of silently appearing settled.

Tracking uses versioned metadata in existing transaction source records, so ordinary Mac edits, iCloud sync, and full backups preserve it without a new CloudKit schema. Older Mac versions do not offer the tracking UI. Their Import as New Journal does not remap tracking links: cloned tracking shows Needs Attention. Remove the unreadable tracking metadata from that journal's Refunds & Reimbursements screen, then recreate the tracking relationships if needed; transaction amounts are kept. Use full restore to preserve tracking IDs and links automatically. The original journal is unaffected by a clone.
