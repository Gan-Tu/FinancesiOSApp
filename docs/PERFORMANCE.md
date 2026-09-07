# Large-journal register performance

Measured on September 7, 2026 with optimized Swift builds on the same Mac. Values are medians of three register preparations. Each synthetic journal has 200 asset accounts and a dense month of balanced transactions.

| Transactions | Register | Before (`92f200c`) | After |
| --- | --- | ---: | ---: |
| 10,000 | All | 274 ms | 117 ms |
| 10,000 | Account group | 1,266 ms | 105 ms |
| 30,000 | All | 1,782 ms | 340 ms |
| 30,000 | Account group | 4,713 ms | 317 ms |

Run `python3 scripts/benchmark_register.py` from the repository. It compiles the actual model and register calculation in a temporary package, with no personal data, network services, or Simulator. The benchmark includes transaction metadata; phone frame rates and receipt image loading require separate device profiling.

Changes:

- Mutate cash-flow buckets in place to avoid repeatedly copying growing transaction-ID sets.
- Accumulate group balances with postings instead of summing every descendant for every row. Multi-currency accounts retain the existing currency-specific projection.
- Ignore sync-only metadata changes when deciding to rebuild the register, and debounce search typing.
- Keep transaction/account row inputs value-based so unchanged rows can skip rebuilding.
- Refresh sync conflicts on completion, cancellation, or failure instead of querying SQLite for every progress update.

Focused checks cover split totals/transaction IDs, filtered running balances, multi-currency transitions, single-currency group totals, and content invalidation. Receipt previews already use asynchronous Quick Look thumbnails; their implementation is unchanged.
