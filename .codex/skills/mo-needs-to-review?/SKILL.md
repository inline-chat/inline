---
name: mo-needs-to-review?
description: Check if uncommitted changes are important/risky/breaking to require a review before merge/production release.
metadata:
  short-description: Does this code need a review from Mo?
---

# Goal
Check if the changes in the current work tree require a second manual review and confirmation from a senior engineer (Mo) who has deep insight into the system or not.

# High-level criteria

If changes match any of the items below, they need a second check:

- Are we adhering to application safety guards regarding encryption and security best practices?
- Are we introducing backward incompatible change to clients or backend?
- Are we removing code that has been used in production previously?
- Are we adding a new RPC or changing protocol in a significant way that could be conflicting/incompatible with our schema as a whole?
- Are we manually interacting with database, migrations, or SQL? Did we remove a migration?
- Are we adding new tables to database?
- Are we adding new environment variables and secrets to the project?
- Are tests not passing or typecheck and lint have errors related to changes? If tests not run, run them to confirm this. 
- Did we change codes related to a core component like database that could lead to new behaviors? 
- Did we intentionally add logs that contain user data or unencrypted secret data?
- Did the review mention any medium/high issues that were ignored? Ensure a review has been run if not already.
- Did we add new RPC or backend modules without writing unit tests for them? Did we use unsafe types like `any`?
- Did we add a new package to bun monorepo without adding it to `Dockerfile`s we have across the project so our build will fail when deploying?
- Did we intentionally instruct the session to ignore a safety standard or important caveat/trade-off that could lead to unsafe production behavior?
- Did we not handle significantly important errors in new backend paths?
- Did we change a UI code that is shared between macOS and iOS but only intended to change it for one and it may introduce unintended side-effects? Ask the user to confirm and if user is unsure, escalate to Mo.

# Static confirmations

Run applicable items from the static check list we have to confirm static behavior.

1. Perform a standard review if not already done in this session.
2. Run build and tests on Swift packages if changed.
3. Run typecheck, lint and tests on backend if changed.
4. Run a build on cli if cli code or protocol has changed.
5. Run a protocol generate command if haven't already and proto has been changed and include the changes in the commits.
6. Run a bun install to confirm dependencies and bun.lock are built if the deps have changed.

# Additional confirmations

- If the changes introduce a significant new UI change, ask the user to send a screenshot or video for review to the senior engineer to confirm. If changes are minimal, trivial, or in an insignificant part of the app (Settings, Experimental UI, Debug screens, etc) skip this.