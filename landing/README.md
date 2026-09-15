# Website and documentation

From the repository root, using Bun 1.4.0:

```sh
bun install --frozen-lockfile
bun run --cwd landing dev
```

Configure local services and credentials separately. Do not commit credentials.

The website uses the browser libraries in `packages/` beneath this
directory.

Run checks individually:

```sh
bun run --cwd landing docs:check
bun run --cwd landing test
bun run --cwd landing typecheck
bun run --cwd landing build
```

Product documentation is in `src/docs/content/`; legal pages are in
`src/legal/content/`.
