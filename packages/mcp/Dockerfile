FROM oven/bun:1.4.0 AS base
WORKDIR /app

FROM base AS pruner
COPY package.json bun.lock bunfig.toml ./
COPY cli/package.json ./cli/package.json
COPY server ./server
COPY landing ./landing
COPY packages ./packages
COPY plugins ./plugins
COPY scripts ./scripts
RUN bun scripts/docker/prune-workspace.ts @inline-chat/mcp out

FROM base AS deps
COPY --from=pruner /app/out/json/ ./
RUN bun install --frozen-lockfile --filter @inline-chat/mcp

FROM deps AS build
COPY --from=pruner /app/out/full/ ./
RUN bun run --cwd packages/protocol build
RUN bun run --cwd packages/oauth-core build
RUN bun run --cwd packages/sdk build
RUN bun run --cwd packages/mcp build

FROM base AS release
COPY --from=pruner /app/out/json/ ./
RUN bun install --frozen-lockfile --filter @inline-chat/mcp --production
COPY --from=build /app/packages/protocol/dist ./packages/protocol/dist
COPY --from=build /app/packages/oauth-core/dist ./packages/oauth-core/dist
COPY --from=build /app/packages/sdk/dist ./packages/sdk/dist
COPY --from=build /app/packages/mcp/dist ./packages/mcp/dist

ENV NODE_ENV=production
ENV PORT=8791

COPY --from=pruner /app/out/full/scripts/docker/smoke-artifact.ts ./scripts/docker/smoke-artifact.ts
USER bun
RUN bun scripts/docker/smoke-artifact.ts mcp
WORKDIR /app/packages/mcp
EXPOSE 8791

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD bun -e "const port = process.env.PORT || '8791'; fetch('http://127.0.0.1:' + port + '/health', { headers: { Host: 'mcp.inline.chat' } }).then((res) => process.exit(res.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["bun", "run", "dist/main.js"]
