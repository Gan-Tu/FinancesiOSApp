# UI audit and accepted corrections

The supplied recording and screenshots were treated as visual references. All saved app captures use synthetic journals and receipts.

| Flow | Correction | Evidence |
| --- | --- | --- |
| Currency selection | Only the selected name/checkmark is blue | [Currency catalog](final/03%20Currency%20Catalog.png) |
| Account creation | Separate name/description, Group In/currency and named color rows; disabled empty Save | [New Account](after/19-new-account.png) |
| Account picker | Indent the complete child label; reserve a trailing selection column inside the card | [Selected account](after/18-selected-account.png) |
| Transaction forms | Consistent card width, separators and amount/currency columns, including large text | [Form](after/11-new-transaction.png) and `large-text/` |
| Register | Month headings scroll away; dot/clip indicators occupy the left gutter; last row remains above the footer | [Oldest row](final/oldest-row.png) |
| Swipe actions | Gray Duplicate, red Delete, blue cleared-state toggle | [Trailing actions](final/swipe-duplicate-delete.png) |
| Duplicate | Original date/time or today's date | [Choices](final/duplicate-choices.png) |
| Recurring delete | Selected occurrence or all future occurrences | [Choices](final/recurring-delete.png) |
| Details | Inline ancestry and account name, full date, bounded receipt, centered blue footer action | [Details](final/transaction-details.png) |
| Monthly breakdown | Currency/category scope and signed cash-flow buckets | [Summary](final/08%20Monthly%20Summary.png) |
| Cloud Sync | Toggle card, one status row and separate actions; help behind the question mark | [Cloud Sync](after/25-cloud-sync.png) |
| App icon | Supplied green coin artwork, full green square with white dollar, no inner circle or badge | [Phone icon](final/phone-icon.png) |

The complete 18-flow iPhone UI suite passed. The final register/Details interactions and monthly summary flow were rerun after their changes. The broader captures in `after/`, `large-text/` and `ipad/` cover settings, backup, security, templates, search, recurrence and picker sheets. Earlier captures remain in `before/` for comparison; five incomplete transition captures were discarded.

The iPad used for inspection and the final iPhone simulator were shut down after verification. The physical phone was restored to normal launch after the live CloudKit suite.

Template account rows were moved above the details and verified in the creation/save flow: [New Template](final/template-accounts-first.png). A scan-enabled template also opened the native document scanner in the UI test.
