# Inline's Server

[![Better Stack Badge](https://uptime.betterstack.com/status-badges/v2/monitor/1murw.svg)](https://uptime.betterstack.com/?utm_source=status_badge)

You need to have bun installed and a postgres database running. Create a database with the name `inline_dev` and adjust the `DATABASE_URL` in the `.env` file. You can make your `.env` file by copying the `.env.sample` file.

```bash
cd server
bun install
bun run db:migrate
bun run dev
```
