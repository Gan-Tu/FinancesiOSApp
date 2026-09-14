# Quick entry

## Home Screen quick actions

Touch and hold the Finances icon to open a new transaction from a template. Settings → Quick Entry & Shortcuts → Home Screen Quick Actions lets you choose and reorder up to four included templates across visible journals. The first available templates are selected initially; removing every shortcut keeps the menu empty. Hidden journals and excluded or deleted templates are never offered.

Quick actions open editable drafts. A template with missing accounts uses the existing account-first selection flow. Incoming actions wait while the app is locked or another editor is open.

## Siri, Shortcuts, Action button and Control Center

Find these actions under Finances in Shortcuts:

- New Transaction: optional journal, amount with currency, payee, and notes; opens an editable draft.
- Use Transaction Template: selects an included template and opens its editor.
- Open Suggestions: opens pending Wallet captures.
- New Transaction with Receipts: accepts image/PDF files and opens a transaction with those receipts.
- Add Apple Pay to Suggestions: captures a purchase for later review without posting it.

The open actions can be assigned using the system's Shortcuts Action button and Control Center options. App Shortcuts include “Log an expense in Finances” and “Use a template in Finances.”

## Receipt sharing

1. Open an image in Photos or a PDF in Files, tap Share, and choose Finances. Look under More if it is not visible in the app row.
2. In New Transaction, choose the journal and accounts, then enter the amount, notes and payee.
3. Tap an attachment's name to preview the image or PDF without leaving the editor. Close the preview to continue editing.
4. Tap Save to record the transaction and its attachments, or Cancel to discard the new draft. Sharing alone does not record a transaction.

If sharing directly from the screenshot preview does not offer Finances or does not open a draft, save the screenshot to Photos and share it from there. Another option is a receipt Shortcut:

1. In Shortcuts, create a shortcut and add the Finances action New Transaction with Receipts.
2. Set Receipts to Shortcut Input.
3. Enable Show in Share Sheet in the shortcut's details, accepting images and PDFs.
4. Share the screenshot or PDF and choose your shortcut in the action list. It opens the same editable transaction flow.

The app copies shared files into a pending local batch. If another editor or the app lock is active, that batch waits without replacing the unfinished editor. Cancel removes the batch; pending batches survive an interrupted launch. After a successful save, their stable identity prevents another copy if the app exits before cleanup.

## Apple Pay Suggestions

Create a personal Wallet/Transaction automation in Shortcuts, select your tapped card, and add Add Apple Pay to Suggestions. Connect Amount (including currency), Merchant, and optionally Card Name, Notes and Date; choose a journal if desired. Run Immediately captures the supported Wallet event without opening the ledger. The app cannot create this personal automation for you or read a card's complete history.

Card Name is the account name in Finances, such as AMEX Platinum. Matching is case-insensitive and requires one matching funding account in the selected journal; an unmatched or ambiguous name requires account selection during review. Notes accepts optional text or a Shortcuts variable and carries through to the transaction draft. Existing automations that omit Notes continue to work.

Check your first capture's currency. If the trigger supplies only a number, explicitly configure Currency Code in the action. No exchange rate is guessed. An unknown card requires account selection; changing journals resets the draft's accounts. A journal without the captured currency cannot save it as a different currency accidentally.

Suggestions are local pending drafts on this device and are not posted balances, iCloud records, or part of a journal backup.

1. Open Suggestions from Journals when captures are waiting. Its row is hidden when empty; Settings → Suggestions is always available.
2. Tap a suggestion and check the journal, accounts, amount, currency and notes.
3. Tap Save to record it as a transaction. Cancel keeps the suggestion for later.
4. To discard a suggestion without recording it, swipe left and tap Dismiss.

Stable capture IDs prevent duplicate conversion after a save/relaunch.
