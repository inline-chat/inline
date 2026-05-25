# Client Release Notes Plan

## Why This Shape

The previous manifest plan still had too many moving parts: fetch an existing manifest, merge into it, sort it, upload it, then hope every client and website route interprets "latest" correctly.

Use immutable release-note files instead. A release publishes one JSON file for the exact build. Native clients fetch the file for the build they are running. The website can use the existing macOS appcast as the macOS version list and fetch a build's release notes only on the detail page.

This keeps v1 small, reliable, and reusable for future clients without designing a release-note database.

## Public Files

For macOS:

- Sparkle appcast stays the update/version list:
  - `https://public-assets.inline.chat/mac/stable/appcast.xml`
  - `https://public-assets.inline.chat/mac/beta/appcast.xml`
- Release notes are immutable per build:
  - `https://public-assets.inline.chat/mac/stable/changelog/12345.json`
  - `https://public-assets.inline.chat/mac/beta/changelog/12346.json`

Future clients can use the same pattern:

- `https://public-assets.inline.chat/ios/stable/changelog/<build>.json`
- `https://public-assets.inline.chat/web/stable/changelog/<build>.json`

No cumulative changelog manifest is required for v1. If a future client needs a list and does not already have an appcast-style release list, add an index later as a derived convenience, not as the core source of truth.

## Release JSON Shape

Each JSON file describes exactly one released build.

```json
{
  "schemaVersion": 1,
  "client": "mac",
  "channel": "stable",
  "version": "1.2.3",
  "build": "12345",
  "date": "2026-05-16T12:00:00Z",
  "commit": "abc1234",
  "downloadUrl": "https://public-assets.inline.chat/mac/stable/12345/Inline.dmg",
  "summary": [
    {
      "title": "Faster chat opening",
      "description": "Chats open with less waiting after launch and reconnects.",
      "icon": "bolt.fill",
      "kind": "improvement"
    }
  ],
  "details": [
    "Fixed a case where an already-downloaded update did not appear as ready to install.",
    "Improved reconnect behavior after the Mac wakes from sleep."
  ]
}
```

`summary` is the app-facing surface. Native clients render title, description, optional SF Symbol icon, and optional kind.

`details` is for full release notes on the website. Keep each entry to one line of Markdown. Native clients do not need to parse it.

Unknown fields are ignored. Future fields must be additive.

## Local Draft

Keep a local draft for the next macOS release:

- `scripts/macos/changelog/next.json`

Draft shape:

```json
{
  "schemaVersion": 1,
  "target": {
    "client": "mac",
    "channel": "stable",
    "version": "1.2.3"
  },
  "summary": [
    {
      "title": "",
      "description": "",
      "icon": "",
      "kind": "improvement"
    }
  ],
  "details": []
}
```

The draft includes `target` so stale notes are caught. The release script validates `target.client`, `target.channel`, and `target.version` against the actual release. The script stamps `build`, `date`, `commit`, and `downloadUrl`.

For a beta release, set `target.channel` to `beta`. If a silent patch should not have release notes, pass an explicit `--skip-changelog`.

## Release Script Changes

Add a validation step near the start of `scripts/macos/release-app.ts`:

- Read `scripts/macos/changelog/next.json`.
- Unless `--skip-changelog` is passed, fail if the draft is missing.
- Validate `schemaVersion === 1`.
- Validate `target.client === "mac"`.
- Validate `target.channel` matches `--channel`.
- Validate `target.version` matches the app marketing version.
- Validate at least one non-empty `summary` item.
- Validate every summary item has `title` and `description`.
- Validate optional `icon` is a non-empty string if present.
- Validate `details`, if present, is an array of non-empty one-line Markdown strings.

Add a publish step after DMG upload verification and before appcast upload:

- Create the final release-note JSON from the draft and stamped build metadata.
- Upload it to `mac/<channel>/changelog/<build>.json`.
- Then upload the appcast.

Publishing notes before the appcast avoids a newly updated app looking for release notes that do not exist yet.

`--skip-changelog` should be explicit and logged in release history. It means no draft validation and no release-note JSON upload for that build.

Do not auto-reset or rewrite `next.json` in the release script. The target validation prevents most stale-note accidents without mutating the working tree.

## Native App Behavior

Add a small macOS feature under `apple/InlineMac/Features/Changelog/`:

- `ChangelogRelease.swift`: codable model for the shared release JSON.
- `ChangelogService.swift`: fetches a specific build's JSON.
- `ChangelogStore.swift`: tracks last seen build per channel in `UserDefaults`.
- `ChangelogWindowController.swift`: owns a singleton native window/panel.
- `ChangelogWindowView.swift`: renders `summary` and a "Full Release Notes" link.

Launch behavior:

- Determine current channel from `AppSettings.shared.autoUpdateChannel`.
- Determine current build from `CFBundleVersion`.
- On fresh install, mark current build as seen and do not auto-show.
- If current build differs from the last seen build for that channel, fetch `mac/<channel>/changelog/<build>.json`.
- If the file exists and has non-empty `summary`, show the "What's New" window.
- Mark the build seen when the user closes the window.
- If fetch fails or returns 404, do nothing. App launch, login, sync, and update installation must not wait on changelog data.

Manual behavior:

- Add "Release Notes..." to the app menu or Help menu.
- Add a link from Updates settings.
- Manual open can fetch the current build's JSON and show the same window, or open the website release-note URL if no local JSON is available.

The native window renders only `summary`. Detailed fixes live on the website.

## Website Behavior

Use the existing appcast parsing as the macOS release list:

- `/changelog/mac/stable`
- `/changelog/mac/beta`

Each release links to a build detail page:

- `/changelog/mac/stable/12345`
- `/changelog/mac/beta/12346`

The detail page fetches `mac/<channel>/changelog/<build>.json` and renders:

- version/build/date
- summary
- details as one-line Markdown entries
- download link from appcast or JSON

If a release-note JSON file is missing, show a small "No release notes for this build" state instead of failing the page.

## Reliability Rules

- The appcast remains the macOS update/version list.
- Release-note JSON is immutable per build.
- Native clients fetch notes only for the exact installed build.
- No client auto-shows "latest" from the server.
- Missing notes are non-fatal.
- Native clients do not parse arbitrary HTML.
- Release metadata is stamped by the release script.
- Draft target validation catches stale channel/version mistakes.
- Stable and beta notes remain separate by path.

## Expansion Points

Later additive fields can include:

- `audience`: `all`, `admin`, `developer`, `beta`
- `severity`: `major`, `minor`, `patch`
- `media`: screenshot or video URLs for website only
- `links`: docs, migration guide, issue, blog post
- `knownIssues`
- localized text blocks

Native clients should continue to depend only on `version`, `build`, `summary.title`, `summary.description`, and optional `summary.icon`.

## First Implementation Slice

1. Add the release-note model and validation helper in scripts.
2. Add `scripts/macos/changelog/next.json` with an empty template.
3. Update `release-app.ts` to validate the draft and upload `mac/<channel>/changelog/<build>.json`.
4. Add landing parser and changelog detail routes backed by appcast + per-build JSON.
5. Add macOS fetch/store/window code.
6. Add menu/settings entry for manual release notes.
7. Test with a local static JSON fixture before wiring the release pipeline.

This version is intentionally smaller: one build creates one release-note file, and clients fetch only what they need.
