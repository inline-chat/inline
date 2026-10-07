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

## Working rules and workflows

- Use .wip, .running and .committing files as hints for coordinating work with sibling agents.

### Worktrees

- Useful for big long feature work, or quick fixes in a dirty workspace that must reach main ASAP. Most changes can happen in the main worktree safely.
- After creating a worktree, copy config files like `apple/Local.xcconfig` alongside it.

### Operational Effectiveness Hints

- Don't run docker, and simulators locally; unless explicitly approved.
- Reserve heavy builds for real checkpoints or after you're done. Avoid too frequent builds that slow us down.
- Don't read .env files, print them, or inspect the contents. It's fine to load them into scripts for normal use or moving them with backups safely.
- For database migrations don't change earlier committed migration, append only.

### Context, memory and responses

- Use `../secret-sauce` for private skills, guides, context, and raw markdown files related to tasks in `../secret-sauce/.context/`; In Secret Sauce, automatically commit relevant work after tasks finish and sync with origin.
- Save plans, research or investigations in `../secret-sauce/.context/YYYY-MM-DD-title-kebab-case.md`. Record my direct ground truth for specs or feedback in the/a markdown file so we accumulate direct ground truth which is useful for future guidance of similar features.
- Keep specs and plans concise and self-contained in chat. Preserve my requirements and feedback as ground truth in the relevant context file, separate from your findings.

### Commits

- Reuse completed checks, stage only the intended changes, verify the staged diff, and commit without unnecessary repeated validation.
- Commit messages should be lowercase and scoped when useful, for example `macos: fix ...`, `server: add ...`, or `chore: ...`.
- When I say “commit” or “finalize and commit” review and validate the change proportionally to its risk, check it against relevant feedback, and make scoped commits.

### Builds, tests, compiles

- When starting a run add an entry to .running file with time started and the command used. Clear once it's done or stale.
- Before attempting a new run, consult that file to see if there is a similar run in progress or other expensive runs that may clog the system resources if you run more simultaneous builds.

### Subagents

If asked to use subagents you can use these models, however most tasks can stay with one agent.

- `luna`, `xhigh`: analyze, find, map, filter, and extract evidence from extensive text. Have the main agent interpret the findings.
- `sol` (`gpt-6.1-sol`): `medium` for small patches; `high` or `xhigh` for implementation, audits, deducting important summaries, and reviews.
- `astra`: `medium` for substantial design or tricky implementation; `high` or `xhigh` for difficult debugging and important correctness reviews.

Be careful if you don't specify subagent model it will inherit the parent.

## Product Design

These are useful invariants, hints, constraints and benchmarks for assessing your implementations. In different situations some of these may not apply or be relevant so do not treat them as strict rules.

- For Apple UI, follow the HIG and established native app patterns where relevant.

- First-frame render is better for chat view, sidebar, messages, draft, compose. In most cases, async load and flickering when we have data locally is bad UX.

- Keep view rendering and scrolling lightweight; avoid blocking I/O and expensive computation on the main thread

- When user asks for a 90/10 solution, they mean how to get 90% of results with 10% of effort. This is a Paul Buchheit term that means not overthinking even largest features and shipping the code/module that can satisfy the use-case in house without relying on third-party, expensive, "official best practices", worrying about scalability, etc that can make a feature take 10x more time. This can come in handy in early prototypes, quick experiments/mockups, infra work when alternatives are costly or too much of a liability, exploring a complex feature, etc.

## Stack

- Hosting and cloud: Fly, Hetzner, Cloudflare (including R2), PlanetScale, Coolify
- Backend and data: Bun, TypeScript, Effect, PostgreSQL, Redis, Drizzle
- Apple clients: Swift, SwiftUI, UIKit, AppKit, GRDB
