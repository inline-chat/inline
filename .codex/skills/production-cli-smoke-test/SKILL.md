---
name: production-cli-smoke-test
description: Safely exercise Inline production through the locally installed `inline` CLI using the authenticated user's self-DM as the default mutation target. Use for important production smoke tests of authentication, messages, file/image uploads, media fetch-back, or recently deployed server routes when a real user-path check is needed without affecting another person or shared chat.
---

# Production CLI Smoke Test

Use the installed `inline` CLI and its existing authentication. Default every
message or upload mutation to the current user's self-DM and verify the result
through a second read.

Read the `inline-cli` skill when it is available. Otherwise inspect
`inline --help` and the relevant subcommand help before guessing flags.

## Safety boundaries

- Require explicit user authorization before sending, editing, deleting, or
  otherwise mutating production. A request to run a production smoke test
  authorizes only the smallest mutation necessary for that test.
- Use the authenticated user's self-DM by default. Never use a space, thread,
  group, bot, or another user's DM unless the user confirms that exact target.
- Discover the current user and self-DM each time. Never hardcode user or chat
  IDs from a prior run.
- Use existing CLI authentication. Never read `.env`, CLI token/config files,
  shell credentials, or signed URL query parameters. Do not print tokens,
  inline media bytes, or complete signed CDN URLs.
- Use a tiny benign payload. Prefer a user-supplied test file or a small public
  asset already in the repo. Never upload private docs, production data,
  credentials, logs containing user data, or unrelated worktree content.
- Do not automatically delete the test message. Report its ID and delete only
  when the user explicitly requests cleanup.
- Do not blindly retry an ambiguous upload failure: storage may have succeeded
  before the response failed. Inspect recent self-DM messages first, then retry
  at most once when evidence shows no message was created.

## Workflow

1. Confirm the binary and authentication without exposing credentials:

   ```sh
   command -v inline
   inline --version
   inline me --json --compact
   ```

   Parse the result internally and report only the user ID/display name needed
   to establish the target.

2. Resolve the self-DM from the current user ID:

   ```sh
   inline chats get --user-id SELF_USER_ID --json --compact
   ```

   Confirm that the returned peer is the same user and that the chat title
   identifies it as the current user's own chat.

3. Select the smallest payload that proves the behavior. For an upload smoke
   test, use a small PNG/JPEG and a caption that clearly marks it as a
   production verification.

4. Send by `--user-id`, not a remembered chat ID:

   ```sh
   inline messages send \
     --user-id SELF_USER_ID \
     --text "Production upload verification" \
     --attach PATH \
     --json --compact
   ```

5. Parse the send response without echoing signed URLs or media bytes. Capture
   the message ID, chat ID, media type, media ID, dimensions, and size.

6. Fetch the exact message back through the CLI:

   ```sh
   inline messages get \
     --user-id SELF_USER_ID \
     --message-id MESSAGE_ID \
     --json --compact
   ```

   Require the fetched message to have the expected sender, self-chat peer,
   caption, media type, and downloadable full-size media metadata.

7. If the test follows a deployment or outage, inspect production logs/Sentry
   only when the user requested operational verification or the CLI result is
   ambiguous. Keep those checks read-only unless separately authorized.

## Result report

Report:

- production operation tested;
- safe target used;
- message/media identifiers;
- payload type and size;
- send and fetch-back outcome;
- whether logs/Sentry were checked;
- any residue left intentionally, such as the test message.

Do not reproduce signed CDN URLs, tokens, inline byte arrays, or unrelated
message contents.
