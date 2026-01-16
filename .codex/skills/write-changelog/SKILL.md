---
name: write-ios-macos-changelog
description: Reads commits and changed files within a timeframe specified by user and compiles a changelog for both iOS and macOS.
metadata:
  short-description: Write changelog for iOS/macOS release
---

If not specified a timeframe, ask the user for a time frame to read commits until then.
Read all commits until specified point in history, list files for each commit and compile a list of new features and fixes for each app. For changes in shared modules, include it for both apps.

Write in past tense. Example:

New

- Added video upload support
- New chat visibility setting: Open chat settings to change who can access the chat

Fixes & Improvements

- Fixed emojis appearing as invalid character
- Fixed video upload failing

# More guidelines

- Prefer 5 to 10 bullets total for most releases.

# Filtering rules

- Include: new features, UI changes, behavior changes, bug fixes users would notice, performance improvements with visible impact.
- Exclude: refactors, dependency bumps, CI changes, developer tooling, internal logging, analytics changes unless they affect user privacy or behavior.
- If a change is ambiguous, ask for clarification or describe it as a small improvement only if it is user-visible.

# Language Guidelines

- Translate technical terms into user-facing descriptions.
- Avoid versions of "API", "refactor", "nil", "crash log", or "dependency".
- Prefer "Improved", "Added", "Fixed", "Updated" or action verbs like "Search", "Upload", "Sync".
- Keep tense present or past: "Added", "Improved", "Fixed".

# QA Checklist

- Every bullet ties to a real change in the range.
- No duplicate bullets that describe the same change.
- No internal jargon or file paths.
- Final list fits App Store text limits for the target storefront if provided.
