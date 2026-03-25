FROM oven/bun:1 AS base
WORKDIR /usr/src/app

FROM base AS pruner
COPY package.json bun.lock bunfig.toml ./
COPY server ./server
COPY web ./web
COPY packages ./packages
COPY scripts ./scripts
RUN bun scripts/docker/prune-workspace.ts @inline-chat/mcp out

FROM base AS development-dependencies
COPY --from=pruner /usr/src/app/out/json/ ./
COPY --from=pruner /usr/src/app/out/bun.lock ./bun.lock
RUN bun install --frozen-lockfile

FROM base AS production-dependencies
COPY --from=pruner /usr/src/app/out/json/ ./
COPY --from=pruner /usr/src/app/out/bun.lock ./bun.lock
RUN bun install --frozen-lockfile --production

FROM base AS build
COPY --from=development-dependencies /usr/src/app/ ./
COPY --from=pruner /usr/src/app/out/full/ ./
RUN cd packages/protocol && bun run build
RUN cd packages/sdk && bun run build
RUN cd packages/oauth-core && bun run build
RUN cd packages/mcp && bun run build

FROM base AS release
COPY --from=production-dependencies /usr/src/app/ ./
COPY --from=build /usr/src/app/packages/mcp/dist ./packages/mcp/dist
COPY --from=build /usr/src/app/packages/oauth-core/dist ./packages/oauth-core/dist
COPY --from=build /usr/src/app/packages/sdk/dist ./packages/sdk/dist
COPY --from=build /usr/src/app/packages/protocol/dist ./packages/protocol/dist

# Install curl/wget for external platform health checks.
RUN apt-get update && apt-get install -y --no-install-recommends curl wget && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production
ENV PORT=8791
ENV INLINE_API_BASE_URL=https://api.inline.chat
ENV MCP_OAUTH_ISSUER=https://api.inline.chat
ENV MCP_OAUTH_PROXY_BASE_URL=https://api.inline.chat

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD sh -c 'curl -fsS -H "Host: mcp.inline.chat" "http://127.0.0.1:${PORT:-8791}/health" > /dev/null || exit 1'

USER bun
WORKDIR /usr/src/app/packages/mcp
EXPOSE 8791
CMD ["bun", "run", "dist/main.js"]
