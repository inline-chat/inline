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

### Working with sibling agents

- If you notice mixed in hunks and diffs mid-committing you may stop committing instead of fighting it.

### Context, memory and responses

- Use `../secret-sauce` for private skills, guides, context, and raw markdown files related to tasks in `../secret-sauce/.context/`; In Secret Sauce, automatically commit relevant work after tasks finish and sync with origin.
- Save plans, research or investigations in `../secret-sauce/.context/YYYY-MM-DD-title-kebab-case.md`. Record my direct ground truth for specs or feedback in the/a markdown file so we accumulate direct ground truth which is useful for future guidance of similar features.
- Keep specs and plans concise and self-contained in chat. Preserve my requirements and feedback as ground truth in the relevant context file, separate from your findings.

### Commits

- Reuse completed checks, stage only the intended changes, verify the staged diff, and commit without unnecessary repeated validation.
- Commit messages should be lowercase and scoped when useful, for example `macos: fix ...`, `server: add ...`, or `chore: ...`.

### Subagents

Use subagents when helpful; most tasks can stay with one agent.

- `luna`, `xhigh`: search, map, filter, and extract evidence. Have the main agent interpret the findings.
- `sol` (`gpt-6.1-sol`): `medium` for small patches; `high` or `xhigh` for implementation, audits, and reviews.
- `astra`: `medium` for substantial design or tricky implementation; `high` or `xhigh` for difficult debugging and important correctness reviews.

Optional workflows:

- Main agent implements; a second agent reviews.
- Main agent focuses on the task; `luna` gathers supporting evidence.
- Main agent defines the scope; `sol` agents implement independent pieces; main agent integrates and verifies.

Keep delegation proportional to the task. Use concise prompts with the goal, scope, and relevant constraints.

### Ship it

When I say “commit” or “finalize and commit” review and validate the change proportionally to its risk, check it against relevant feedback, and make scoped commits.

### Adversarial reviews

Use an independent adversarial review for substantial or risky changes, especially in core modules. Small, straightforward changes can use a self-review or finalization pass.

### iOS devices

To run labs, experiments, and test your changes in the app, ask the user to connect their device and open device hub to keep it unlocked and access the device using `Device Hub.app` or through any other means.

### When user is gone
When I’m unavailable, continue useful work within the authorized scope. If blocked, explain what’s needed and suggest how to avoid the blocker next time.

### Multi-monitor

When user has two monitors, try to run macOS visual tests and labs in their second monitor (smaller one) to not interrupt their workflow (unless they aren't around.)

### Summarize changes

Summarize what changed, how it was validated, and any important risks or remaining gaps. Mention public API or UX changes and relevant artifacts when useful.

## Product Design

These are useful invariants, hints, constraints and benchmarks for assessing your implementations. In different situations some of these may not apply or be relevant so do not treat them as strict rules.

- First-frame render is better for chat view, sidebar, messages, draft, compose. In most cases, async load and flickering when we have data locally is bad UX.

- Keep view rendering and scrolling lightweight; avoid blocking I/O and expensive computation on the main thread

- When user asks for a 90/10 solution, they mean how to get 90% of results with 10% of effort. This is a Paul Buchheit term that means not overthinking even largest features and shipping the code/module that can satisfy the use-case in house without relying on third-party, expensive, "official best practices", worrying about scalability, etc that can make a feature take 10x more time. This can come in handy in early prototypes, quick experiments/mockups, infra work when alternatives are costly or too much of a liability, exploring a complex feature, etc.

## Stack

- Hosting and cloud: Fly, Hetzner, Cloudflare (including R2), PlanetScale, Coolify
- Backend and data: Bun, TypeScript, Effect, PostgreSQL, Redis, Drizzle
- Apple clients: Swift, SwiftUI, UIKit, AppKit, GRDB
- Web client: React, TanStack Router, Vite
- CLI and contracts: Rust, Protocol Buffers
- CI and builds: GitHub Actions, Xcode Cloud
