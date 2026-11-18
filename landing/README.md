# Website and documentation

From the repository root, using Bun 1.4.0:

```sh
bun install --frozen-lockfile
bun run --cwd landing dev
```

Configure local services and credentials separately. Do not commit credentials.

The website shares `@inline/config` with the web app in `web/packages/`.

Run checks individually:

```sh
bun run --cwd landing build
bun run --cwd landing typecheck
bun run --cwd landing lint
bun run --cwd landing test
```

Product documentation is in `src/docs/content/`; legal pages are in
`src/legal/content/`.
