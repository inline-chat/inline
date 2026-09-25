# Instructions for landing

## Scope

- `landing/` contains the website, web app, docs, legal pages, and download routes. It uses React, TanStack Router, Vite, and StyleX/Tailwind; keep server rendering safe.

## Checks

- From `landing/`, use `bun run docs:check` for docs changes and the relevant `typecheck`, `lint`, `test`, or `build` script at a useful checkpoint. Start `bun run dev` only when a local server helps the task.

## UI and docs

- Prefer existing tokens and utilities; check light and dark appearances.
- Docs Markdown lives in `landing/src/docs/content/`. Update `landing/src/docs/sidebar.json` or `technical-sidebar.json` when navigation changes.
- Write concise, reference-first docs with exact commands and limits. Keep the public changelog in `landing/src/docs/content/changelog.md` newest first, with build numbers and download links for releases when available.
