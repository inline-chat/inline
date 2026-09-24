# Server development

The server uses Bun 1.4.0 and PostgreSQL. CI currently tests against PostgreSQL 15.
This is a developer entry point, not a supported self-hosting guide.

From the repository root:

```sh
bun install --frozen-lockfile
```

Provision local configuration and a dedicated development database before starting.
Credentials are not included in the repository.

Confirm that your database is a dedicated development database and review pending
migrations before running:

```sh
bun run --cwd server db:migrate
bun run dev:server
```

Migrations change the configured database. Verify the target database and back up
any data you need to keep before applying them.
Server startup only verifies the migration ledger and refuses a database behind
the packaged journal. Production migrations are a separate deployment step;
see [Fly deployment and migrations](docs/fly-deployment.md).

Run validation individually, with a separately configured test database:

```sh
bun run --cwd server typecheck
bun run --cwd server lint
bun run --cwd server test
```

See [TESTING.md](TESTING.md) for fast no-database checks, focused runs,
isolated PostgreSQL tests, coverage priorities, and test-writing conventions.
The canonical runner creates disposable databases and never resets the database
named in `TEST_DATABASE_URL`. CI uses a disposable PostgreSQL service in
[server-test.yml](../.github/workflows/server-test.yml).

Security reports: [SECURITY.md](../SECURITY.md).
