# Repository Instructions

## Tests Before Push

- Run the relevant build and tests after making changes and before pushing.
- If any tests fail locally or in Xcode Cloud, investigate and fix the failures before pushing. Rerun every failing test and the related regression checks until they pass.
- Reproduce cloud failures on the same iOS version and device configuration when available. Passing on an older runtime alone does not validate a failure on a newer runtime.
- Preserve meaningful assertions and test coverage. Do not skip, disable, or weaken tests merely to make a release pass; correct brittle test interactions while preserving the behavior being verified.
- If the required build or tests cannot run, validation is incomplete. Report the blocker and do not push unless Gan explicitly authorizes an exception.
- After pushing, verify that the remote branch matches the local commit. Distinguish a successful push from successful Xcode Cloud tests, archive, and TestFlight delivery.
- Xcode Cloud is this project's automated test and release pipeline. Do not reintroduce the removed GitHub Actions workflow without an explicit request.
