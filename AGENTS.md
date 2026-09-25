# Instructions

## Project

- Inline is a chat app for work. With a focus on performance, native experience, agentic workflows, and thread-first chat.
- Website: inline.chat. api.inline.chat.

## Repository

- `apple/`: native iOS and macOS clients.
- `server/`: Bun and TypeScript backend.
- `landing/`: website and product documentation.
- `proto/`: canonical protocol schemas.
- `packages/`: shared TypeScript packages, including the SDK, protocol, bot client, and MCP server.
- `plugins/`: ChatGPT, OpenClaw, Hermes, and other integrations.
- `cli/`, `crates/`, `vendor/`: Rust CLI, workspace crates, and vendored dependencies.
- `skills/inline/`: distributable Inline agent skill.
- `scripts/`: repository maintenance and development scripts.
- `.github/`, `.codex/`, `.agents/`: CI configuration and agent tooling.
- Root manifests include `package.json`, `bun.lock`, `Cargo.toml`, `Cargo.lock`, and `rust-toolchain.toml`.

## Working rules

- Use .wip, .running and .committing files as hints for coordinating work with sibling agents.

### Operational Effectiveness Hints

- Manage local system resources RAM/CPU/Disk if you detect they are under pressure and coordinate in the best manner.
- Do not run docker runs locally.
- Do not run simulators unless explicitly approved.
- Try to not run checks and heavy builds after every small change. It's best to manage our resources and do checks at real checkpoints when necessary.
- Prefer taking a backup before running destructive commands.
- Don't read .env files, print them, or inspect them. It's fine to move them with a script with strict care to not expose them.
- Be careful with database migrations to not accidentally change an earlier migration and mess up the database.
- Before shipping a user-facing action, verify that it can perform its stated behavior. If a missing contract or unclear fallback would make it inert or misleading, ask the user instead of silently degrading the action or its copy.

### Working with sibling agents

- Read/modify .wip, .running and .committing files as hints for coordinating with other agents. Files currently changed are listed in .wip. Build commands running are in go in .running, and in progress commits go in .committing. There may be stale values in those so don't get stuck.
- If you notice mixed in hunks and diffs mid-committing you may stop committing instead of fighting it.
- Final handoffs should explain the issue and fix technically, call out security/performance/compatibility risks, mention production readiness, and state validation performed or skipped, and anything else an engineer should know.

### Context, memory and responses

- Use `../secret-sauce` for private skills, guides, context, and raw markdown files related to tasks in `../secret-sauce/.context/`; In Secret Sauce, automatically commit relevant work after tasks finish and sync with origin.
- Save plans, research or investigations in `../secret-sauce/.context/YYYY-MM-DD-title-kebab-case.md`. Delete discarded or superseded ones.
- For every spec or plan, print a self-contained version in the chat response. Always include the high-level design, concrete specification, scope of work, and a few short representative schema/code snippets. Do not stop at linking to a Markdown file; saved documents are supporting artifacts because the user rarely opens them.
- When iterating on a feature, and i give you bullet lists of feedback, spec, and alike, record all of my words in a massive spec bullet list and accumulate my feedback as ground truth in a separate markdown file for that feature so you and future rounds of agent still have my direct spec/feedback as ground truth. This file must be free from your own investigations. Only modify previous items if i contradict them explicitly. Treat these as quotes of me and don't modify them. add additional context in brackets or something if I make unclear claims. Fix grammar and types, that's fine.
- When brainstorming or writing specs for a refactor, rewrite, or weighing a change, new feature or fix for a major flaw in the core logic of a core module like realtime, sync, message lists, message views, chat view, chat view model, dbs, etc, first check prior research, labs, findings, my ground truth, and brainstorming sessions from secret-sauce's context or memory to understand the larger goals and plans so you can be more aligned by keeping the vision for those modules in mind when changing them.

### Brainstorming

- When brainstorming plans, research and early spec-like documents, keep the results concise, yet with detailed technical details and decision-focused. Start as small as possible without losing requirements or leaving ambiguity; omit obvious details and implementation noise. Unless the user asks otherwise.

### Commits

- Keep commits fast: before committing, run one concise finalization/review pass and apply relevant formatting fixes, reusing any equivalent checks already completed instead of repeating them. Then register `.committing`, stage exact paths/hunks, inspect `git diff --cached --name-only` once, and commit immediately; prefer `scripts/committer "<msg>" <file...>` when whole-file ownership is clean.

- Commit messages should be lowercase and scoped when useful, for example `macos: fix ...`, `server: add ...`, or `chore: ...`.

### Large evidence and review

These are optional ways to keep large investigations readable:

- For builds, historical logs, traces, research, and large diffs, save noisy output, check its size, then extract relevant errors, sources, and hot paths instead of loading entire artifacts into the session.
- For extensive evidence or diff review, experiment with different filters and after a good filter use a `luna` subagent to distill signal from noise. Keep feature implementation in the main task unless the user explicitly delegates it.
- You may use `sol` subagents to implement scoped changes to keep you main task focused. `luna` subagents are useful for plowing through lots of raw research materials and markdowns to find relevant bits to your goals.
- Downsize oversized screenshots (2x -> 1x) and use sprite sheets for video frames when useful.

### Subagents

Optionally spin subagents, you may choose different models and reasoning efforts depending on the workflow.
Hints on which to use for what:

- `luna` for mapping, filtering, extracting. Reasoning effort `xhigh`.
- `sol` for review, audit, deep dives. Reasoning effort from `high` and `xhigh`. `med` for small quick patches and checks.
- `astra` for reviews when parent model was astra already, extremely tricky stuff, and tricky implementations, research or debugging with multiple rounds of failure to achieve the goal. Reasoning efforts from `med` to `xhigh` for extreme cases. `light` for small quick patches and checks.

Some workflows to pick from. Keep in mind you do not have to run any subagents unless it's needed based on criteria mentioned or user explicitly asks for.

- One main `astra` or `sol` agent: most of work does not require subagents and should be done within one parent agent with no subagent.
- `astra` brainstorming and writing spec. one or multiple `sol` xhigh implementing. if multiple were implementing, parent `astra` would check the difference results and merge them itself or another `sol`.
- `sol` xhigh or high implementing, `astra` doing an adversarial review.
- Main `astra` or `sol` agent focusing on task, `luna` xhigh plowing through evidence corpse.
- Main `astra` or `sol` agent doing the work, after finishing one adversarial review, and one fixer agent working sequentially to finalize the complex task.

You can tweak, mix, or change these. There are just ideas.
For prompting these subagents, you may also pick one of the general directions:

- Default - whatever you see fit.
- Keeping the prompt concise and high level and letting their thinking help you navigate the idea space as well. (Do not do this with `luna`.)
- Making the prompt detailed in terms of spec and constraints and ground truth and helping the subagent stay within the intended scope with public edges and high level design provided as strong guidelines.

### Reviews

- When asked to review your work, run an adversarial review subagent that assumes something like: "Assume changes are wrong, done without care or understanding the root cause. They are done by a junior engineer who just wanted to get it done fast and move on." Something long those lines. For important changes use `astra` model or inherit the parent threads model. For scoped reviews or changes use `sol` agents. If you are confident in the change and it's not extensive or doesn't touch anything of substance, skip running subagents and do a quick review and finalization pass yourself.

## Product Design

These are useful invariants, hints, constraints and benchmarks for assessing your implementations. In different situations some of these may not apply or be relevant so do not treat them as strict rules.

- First-frame correctness is non-negotiable: persisted state required for presentation must be present before initial row/view construction. Never render known-wrong content and remove it after an observer fires.

- Rendering and scrolling paths must remain pure and lightweight. Do not perform database reads, network work, heavy setup, or blocking waits in view/cell construction or on the main thread.

- Before implementation, compare the proposed slice with a plausible overbuilt version and delete fields, timestamps, states, layers, and edge-case machinery that are not required by the accepted contract. Keep the rejected before/after as reusable design evidence when it reveals a general pattern.

- Public Inline's `spaces` (aka workspaces) should be treated as internet-accessible unless banned. Default to minimum member/user data disclosure.

- Start every feature spec with a complexity budget: durable fields, RPCs/updates, migrations, new state owners/observers, background tasks, UI row types, and touched subsystems. Any item beyond the minimum requires a concrete invariant it protects.

- Try to avoid adding parallel observers, duplicate state, generic registries, custom non-standard patches, unless this is an experimental thing or hot fix or something we'll get rid of later. In that case, keep the impact scoped from leaking so it can easily be replaced later.

- Keep v0.1 boundaries honest. If the user accepts a bounded imperfection, record and test that limitation instead of solving it through unrelated infrastructure. Surface unavoidable correctness risks for sign-off; never smuggle a large prerequisite into a small feature.

## Stack

- Hosting and cloud: Fly, Hetzner, Cloudflare (including R2), PlanetScale, Coolify
- Backend and data: Bun, TypeScript, Effect, PostgreSQL, Redis, Drizzle
- Apple clients: Swift, SwiftUI, UIKit, AppKit, GRDB
- Web client: React, TanStack Router, Vite
- CLI and contracts: Rust, Protocol Buffers
- CI and builds: GitHub Actions, Xcode Cloud
