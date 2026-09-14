Inline CLI 0.7.14 includes the current Claude and Codex bridge reliability fixes.

- Fix Claude setup checks stalling when a provider probe inherits a controlling terminal.
- Refresh Codex model choices and effective defaults, and publish freshly loaded choices to Agent configuration.
- Honor explicit reasoning when the model is Automatic.
- Show bounded, scrubbed provider explanations for failures and retry progress.
- Add Codex usage windows and reset times to `/status`.
- Track `/compact` through completion, failure, and `/stop`; Agent Settings directs users to the tracked command.
- Improve Codex activity summaries with grouped completed work, readable command previews, and file change details.
- Continue processing later updates when a newer server sends an additive update the CLI does not project.

Available for Apple silicon macOS and Linux ARM64/x86-64 with GNU and musl variants. macOS artifacts are signed and notarized.
