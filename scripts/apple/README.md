# Apple Sentry Uploads

Local iOS archives now upload dSYMs automatically from the `InlineIOS` Xcode target's Release/archive build phase.

Use `scripts/apple/upload-dsyms.sh` directly when you want a manual fallback after an `xcodebuild archive`, or from other archive paths.

Manual usage:

```sh
scripts/apple/upload-dsyms.sh --archive-path /path/to/InlineIOS.xcarchive
```

Use `--dry-run` to verify the archive path and discovered `.dSYM` bundles without uploading anything.

The script defaults to:

- `SENTRY_ORG=usenoor`
- `SENTRY_PROJECT=inline-ios-macos`
- `SENTRY_API_URL=https://us.sentry.io`

Auth comes from `SENTRY_AUTH_TOKEN`, or locally from an authenticated modern `sentry` CLI session via `sentry auth token`.

Xcode Cloud:

- Use `scripts/apple/ci_post_xcodebuild.sh`.
- Set `SENTRY_AUTH_TOKEN` in the workflow environment.
- The script uploads from `CI_ARCHIVE_PATH/dSYMs` when `CI_XCODEBUILD_ACTION=archive`.
