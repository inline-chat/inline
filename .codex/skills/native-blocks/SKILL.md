---
name: native-blocks
description: Add or change a native message block (agent cards such as plans, approvals, reviews, task suggestions, questionnaires) across proto, server, bridge, macOS and iOS. Use when Claude, ChatGPT or Codex clients ship a new card, or a block needs a new field.
---

# Native message blocks

Inline draws agent surfaces (plans, approvals, review notes, task suggestions, next steps, prompt chips, questionnaires) as typed protocol blocks with native views on macOS and iOS. HTML widgets are not a substitute. Each upstream surface gets its own block kind when it has its own look or behaviour.

## Contract every block keeps

- Every user-visible string in a block is a `BlockText` UTF-16 range into `Message.message`. That text is the complete readable fallback for older clients, notifications, search and copy. Machine strings (ids, composer text, categories) are plain fields.
- Ranges of top-level blocks are ascending and don't overlap. The server enforces this.
- A client that can't draw a block shows the text it covers and draws everything else (`BlockContentSpan` in InlineKit). A kind newer than the build shows the text between its neighbours; inside a container, `BlockContentSpan.childBounds` stands in for missing neighbours, so pass it to nested layouts of any new container kind (and add the kind there). Never fail a whole message because of one block.
- Buttons are ordinary `Message.actions` referenced by id (`action_ids`). Clients draw them inside the block and drop them from the action rows (`BlockInlineActions`). Older clients keep them in the rows, still working.
- State that changes (decision state, step status, who decided) lives in the block. The sender edits the message. Edits are realtime-only: no push, and "edited" shows only in the context menu.
- Composer text goes through `MessageActionCompose` / `MessageComposeRequests`. It is appended to the draft and never sent by itself. Post it with `post(_:from:isThreadAnchor:)`: a message shown as a thread's anchor fills that thread's composer, not the parent chat's.

## Adding a surface: the order of work

1. **Is it a recipe or a new kind?** If an existing block draws it faithfully, add only a bridge recipe (step 7). Otherwise add a kind.
2. **Proto**: add the kind to `Block.kind` in `proto/core.proto` (next free number), with its message and a comment saying what its fallback text carries. Run `bun run generate:proto`, then `bun run proto:sync-rust`. Call out the proto change before committing.
3. **InlineKit** (every switch is exhaustive, so the build lists each place):
   - `BlockContentSpan.span(of:)`: every text range of the kind.
   - `BlockContentReconciler`: a `BlockContentNodeKind` case; flatten children.
   - `BlockContentDirection`: `declaredDirection` and `resolve` if it has `is_rtl`.
   - `Message.materializeBlockPhotos` if it can hold images.
   - `BlockInlineActions.collect` if it has `action_ids`.
   - Tests in `apple/InlineKit/Tests/InlineKitTests/BlockContentSpanTests.swift`.
4. **Server**: validation (ranges, caps, `action_ids` exist, span order) and the bot API encode/decode in `server/src/controllers/bot/richContent.ts` and `packages/bot-api-types`. TS switches end in `satisfies never`.
5. **macOS**:
   - A plan node in `RichBlockAgentPlan.swift` plus `RichBlockLayoutPlan.NodeKind` and `RichBlockRenderKind`.
   - Layout in `RichBlockLayoutPlanner+AgentCards.swift` (or `+Agent.swift`) with manual measured layout. Card-shaped blocks reuse `beginCard`/`appendActions`/`endCard`.
   - A node view in `RichBlockAgentCardNodeViews.swift`, registered in `RichBlockViewFactory`.
   - Text parts are `RichBlockTextSurface`s listed in `orderedTextSurfaces`, so selection and copy work.
6. **iOS**: the builder in `apple/InlineIOS/Features/MessageView/MessageRichContent.swift`, the `RichBlock` node in `apple/InlineMessageLayout`, and the view in `MessageRichView.swift`. Match macOS: light and dark, RTL, Dynamic Type, VoiceOver.
7. **Bridge recipe**: `cli/src/bridge/v2/blocks/<surface>.rs` maps the native tool call or item to the block. Add a native sample in `blocks/fixtures/<surface>/` and a golden test of blocks plus fallback text. Register it in the table in `blocks/mod.rs`. If the surface is a host tool in Claude or ChatGPT desktop, add an Inline tool in `cli/src/bridge/v2/tools.rs`.
8. **Check**:
   - `swift test` in InlineKit and InlineMessageLayout.
   - Server tests for the validation.
   - `cargo test` for the recipe.
   - One macOS build and one iOS build.
   - Look at the block in light, dark and RTL, at a narrow width, and as fallback text:
     - **macOS:** add a fixture to the Developer Playground ("Rich content blocks", in `DeveloperPlaygroundMessageCatalog.swift`); Window > Open Playground (⌥⌘P) in a debug build.
     - **iOS:** add the block to `apple/InlineMessageTests/AgentBlocksCatalogTests.swift`. Run `xcodebuild test -scheme "Inline Message Tests" -only-testing:InlineMessageTests/AgentBlocksCatalogTests` on one simulator, with `TEST_RUNNER_AGENT_BLOCKS_SNAPSHOT_DIR=<dir>` to get light and dark PNG sheets.

## Log of upstream surfaces

| Surface | Source | Block | Since |
|---|---|---|---|
| Task list / plan | Claude TodoWrite, desktop task list; Codex update_plan | `steps` (pinned at bottom of progress) | 2026-11-15 |
| Questionnaire | AskUserQuestion; request_user_input | `form` + header, preview, recommended | 2026-11-15 |
| Plan approval | ExitPlanMode; Codex proposed plan | `plan_proposal` | 2026-11-15 |
| Approval | permission / exec / patch approvals | `approval` | 2026-11-15 |
| Review notes | ReportFindings; Codex review mode | `review` | 2026-11-15 |
| New task card | desktop start_session | `task_suggestion` (Inline tool `suggest_thread`) | 2026-11-15 |
| Next step box | desktop wrap_up | `next_step` (Inline tool `ask_next_step`) | 2026-11-15 |
| Prompt chips | suggested prompts | `prompt_suggestions` (Inline tool `suggest_prompts`) | 2026-11-15 |
| Queued | file-change summary, sources, chapter, artifact card | — | |

Spec and product ground truth: `../secret-sauce/.context/2026-11-15-native-agent-blocks.md`.
