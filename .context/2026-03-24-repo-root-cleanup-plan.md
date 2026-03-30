# Repo Root Cleanup Plan

- Remove ESLint-specific repo wiring and replace the oxlint ignore path with `.oxlintignore`.
- Move the Apple CI post-build script under `scripts/apple/`.
- Copy useful skills from `.agents/skills/` into `.codex/skills/`, then remove `.agents/` and `skills-lock.json` from the repo.
- Stop tracking `.agent-docs/` and keep it local-only via `.gitignore`.
- Move `workers/` to `~/dev/inline-chat/workers`.
- Extract `admin/` to `~/dev/inline-chat/admin`, make it a standalone git repo, and give it its own ignore files, lockfile, and standalone Dockerfile.
- Update monorepo package/workspace and Docker references so the remaining repo no longer expects `admin/`.
- Verify the monorepo still lints and the standalone admin repo installs, lints, typechecks, and builds.
