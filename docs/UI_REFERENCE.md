# UI reference and companion coverage

The supplied 100-second recording was inspected throughout at eight-second intervals and again at two-second intervals for the detailed flows. The recording is a visual/interaction reference, not an instruction source. It and its personal financial information are not included in this repository.

| Recording | Observed flow | Implementation |
| --- | --- | --- |
| 0–10s | Journals, transaction count, create journal and currency/template selection | Journals root, native editor, search-capable currency catalog, Personal/Business templates, empty starting balances |
| 12–34s | Empty register, account selection, signed amounts, split posting, recurrence and notes | Empty states, searchable account picker, Decimal arithmetic keyboard, multiple postings, interval/count/end-date recurrence |
| 38–56s | Account groups, account register, cleared state and recurring deletion | Expandable nested groups, account-context entry, running balances, swipe actions, explicit series confirmation |
| 56–60s | Transaction templates | Create/edit/reorder/enable templates and start transactions from them |
| 62–76s | Large journal, compact rows, monthly totals, chart, account breakdown | Searchable month/day register, separate currencies, chart period selection and monthly account drill-down |
| 78–86s | Transaction details and receipt previews | Readable postings, notes/payee/date, thumbnail previews, Quick Look, direct attachment import |
| 90–100s | Editing an existing transaction and adding a split | Native modal editor, account and currency selection, arithmetic controls, balancing action |

The app uses compact grouped forms and plain navigation chrome to match the recording. The iOS 26 build enables Apple’s UI compatibility mode; form geometry is controlled directly rather than relying on changing system row padding. Apple ignores that compatibility flag when linking against the iOS 27 SDK, so navigation chrome must be reviewed when upgrading the pinned Xcode toolchain. iPad uses the same navigation and forms at its available size. It intentionally does not implement the Mac command palette.

Both companions support deleting only the selected recurring entry, including the first, or deleting that entry and all future occurrences. A retained schedule anchor preserves month-end cadence and occurrence counts after the first entry is removed. Imported custom recurrence rules are preserved; new schedules use daily/weekly/monthly/yearly frequencies with configurable intervals, workdays and endings.

Receipt scanning captures document pages; it does not infer a transaction amount/payee with OCR. No analytics, third-party account connection, or third-party original Finances CloudKit access is added.

## Spacing and alignment pass

The recording is 1320 × 2868 pixels (440 × 956 points at 3×). The transaction, journal, repeat/end-repeat, account, currency and template forms were revisited after the owner’s spacing correction.

- About 47-point form rows, matching the recording’s row-to-row spacing after normalizing both screenshots to the same dimensions.
- 22-point page insets and 20-point internal row insets, 10-point corners and one-pixel separators.
- A shared trailing edge for amount fields and a fixed currency column. Account-name length no longer moves the amount field.
- The green add-posting control sits below its card. The first section gap is 32 points after that control; later section gaps are 20 points.
- Repeat and End Repeat are navigation rows, with Cleared in the same card. Scheduling controls live on dedicated screens.
- New Journal has a large title and separate name, currency and template sections with checkmarked template rows.
- The currency and account search drawers can be revealed by pulling down, preserving the recording’s compact initial presentation.
- Templates remain available through the transaction section menu and compose customization, instead of adding an extra register-navigation row.

The geometry UI test checks that amount edges align, posting rows have the intended spacing, and Notes/Payee/Number share a leading edge and consistent row spacing. Minimum row heights scale with Dynamic Type.

## Follow-up screenshot corrections

- Currency choices use blue only for the selected currency name/checkmark. Other names are the system label color and currency codes remain secondary gray.
- New Account matches the supplied reference: Name and Description, Group In and Currency navigation rows, then a vertical list of named colors with a trailing blue checkmark. Save stays disabled until a nonblank name is entered.
- Account picker rows include descriptions and a trailing currency. Asset/liability/equity rows omit color dots; income/expense dots move together with the text by 22 points per nesting level.
- The main account list uses the same whole-label indentation. Subaccount collapse remains available from the account context menu without adding a layout-shifting chevron before its label.
- Transaction text starts at one fixed column. Uncleared gray dots and receipt clips occupy an independent left gutter in registers and Quick Search. Registers no longer reserve space for an automatic trailing navigation chevron.
- Edit selection uses the same gutter, and the normal sync/compose footer hides while bulk editing so it cannot cover Clear/Unclear controls.
- The latest iOS icon is a full green square with the white dollar symbol and no inner circle; the blue selection tint is unchanged. See `ICON.md` for the supplied source artwork and opaque asset packaging.
- Cloud Sync matches the later screenshot: a large toggle/explanation card, one status row, and Synchronize Now/Reset action rows. Help and diagnostic details are behind the question-mark button. Conflicts open a dedicated review sheet.
- Registers with future scheduled entries start near today; future-only registers start at the nearest scheduled date. Upcoming rows remain reachable above, and the Uncleared badge counts entries through today.

## Final register and Details corrections

Month headings scroll as ordinary rows. The bottom toolbar participates in each screen’s safe area, so the oldest row stays visible after scrolling settles. Swipe left exposes gray Duplicate and red Delete. Duplicate offers the original date/time or today; ordinary deletion is immediate, while recurring deletion asks for its scope. Swipe right toggles Cleared/Uncleared. Tapping an entry opens Details.

Details use an inline, wrapping gray ancestry prefix with a regular black account name, gray amounts, full weekday dates and 24-hour time. Receipt thumbnails occupy a bounded 210-point preview with a subtle border. The footer has a left action menu and centered blue Delete Transaction. Monthly summaries now bucket refunds and spending by cash-flow sign, resolve default currencies, and preserve currency/category filters in account breakdowns.

Final synthetic captures are in `ui-audit/final/`; the broader iPhone, large-text and iPad audit captures are in the adjacent folders.

Template account rows now appear first, followed by name, payee, note and options. Scan Invoice is connected to the receipt scanner when the template is used.
