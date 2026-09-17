# Repository Instructions

## No Real Inference During Development or Verification

- Never use real model inference for testing, verification, development, demos, or release checks. This includes chat, voice, receipt analysis, external providers, and production endpoints.
- Use deterministic mocks, recorded fixtures, and injected fake transports only. Existing API keys and earlier permissions to reuse keys do not authorize test inference.
- Do not enable paid calls to verify a deployment or bypass the development/Simulator inference guards. Production inference is for normal user operation only.
- Keep UI coverage using the mock assistant gateway; never restore a live-inference opt-in test path.
- Ask AI defaults to `gpt-5.6-terra` with medium reasoning when no saved override exists. Preserve valid user-selected models and effort levels.

## Tests Before Push

- Run the relevant build and tests after making changes and before pushing.
- If any tests fail locally or in Xcode Cloud, investigate and fix the failures before pushing. Rerun every failing test and the related regression checks until they pass.
- Reproduce cloud failures on the same iOS version and device configuration when available. Passing on an older runtime alone does not validate a failure on a newer runtime.
- Preserve meaningful assertions and test coverage. Do not skip, disable, or weaken tests merely to make a release pass; correct brittle test interactions while preserving the behavior being verified.
- If the required build or tests cannot run, validation is incomplete. Report the blocker and do not push unless Gan explicitly authorizes an exception.
- After pushing, verify that the remote branch matches the local commit. Distinguish a successful push from successful Xcode Cloud tests, archive, and TestFlight delivery.
- Xcode Cloud is this project's automated test and release pipeline. Do not reintroduce the removed GitHub Actions workflow without an explicit request.

## Xcode Cloud Usage Budget

- Keep the `FinancesiOS` release scheme limited to its small smoke-test selection. Do not add UI audits, performance sweeps, or large-file stress tests to routine TestFlight builds without Gan's request.
- Preserve the complete suite in `FinancesiOSFullTests`. Use `scripts/test.sh` for full or targeted local regression checks and `scripts/test.sh --smoke` for the exact cloud selection.
- Reducing cloud coverage is an intentional cost limit, not permission to ignore a failure. Run the smoke suite and the relevant local regressions before pushing, and fix failures first.
