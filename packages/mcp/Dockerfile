FROM oven/bun:1 AS base
WORKDIR /usr/src/app

# Install dependencies into temp directory with devDependencies.
FROM base AS development-dependencies
RUN mkdir -p /temp/dev
COPY package.json bun.lock /temp/dev/
COPY admin/package.json /temp/dev/admin/
COPY server/package.json /temp/dev/server/
COPY server/packages/email-preview/package.json /temp/dev/server/packages/email-preview/
COPY server/packages/email-templates/package.json /temp/dev/server/packages/email-templates/
COPY web/package.json /temp/dev/web/
COPY web/packages/auth/package.json /temp/dev/web/packages/auth/
COPY web/packages/client/package.json /temp/dev/web/packages/client/
COPY web/packages/config/package.json /temp/dev/web/packages/config/
COPY web/packages/log/package.json /temp/dev/web/packages/log/
COPY web/packages/protocol/package.json /temp/dev/web/packages/protocol/
COPY packages/bot-api-types/package.json /temp/dev/packages/bot-api-types/
COPY packages/bot-api/package.json /temp/dev/packages/bot-api/
COPY packages/mcp/package.json /temp/dev/packages/mcp/
COPY packages/oauth-core/package.json /temp/dev/packages/oauth-core/
COPY packages/openclaw-inline/package.json /temp/dev/packages/openclaw-inline/
COPY packages/sdk/package.json /temp/dev/packages/sdk/
COPY packages/protocol/package.json /temp/dev/packages/protocol/
COPY scripts/package.json /temp/dev/scripts/
RUN cd /temp/dev && bun install --frozen-lockfile

# Install production dependencies only.
FROM base AS production-dependencies
RUN mkdir -p /temp/prod
COPY package.json bun.lock /temp/prod/
COPY admin/package.json /temp/prod/admin/
COPY server/package.json /temp/prod/server/
COPY server/packages/email-preview/package.json /temp/prod/server/packages/email-preview/
COPY server/packages/email-templates/package.json /temp/prod/server/packages/email-templates/
COPY web/package.json /temp/prod/web/
COPY web/packages/auth/package.json /temp/prod/web/packages/auth/
COPY web/packages/client/package.json /temp/prod/web/packages/client/
COPY web/packages/config/package.json /temp/prod/web/packages/config/
COPY web/packages/log/package.json /temp/prod/web/packages/log/
COPY web/packages/protocol/package.json /temp/prod/web/packages/protocol/
COPY packages/bot-api-types/package.json /temp/prod/packages/bot-api-types/
COPY packages/bot-api/package.json /temp/prod/packages/bot-api/
COPY packages/mcp/package.json /temp/prod/packages/mcp/
COPY packages/oauth-core/package.json /temp/prod/packages/oauth-core/
COPY packages/openclaw-inline/package.json /temp/prod/packages/openclaw-inline/
COPY packages/sdk/package.json /temp/prod/packages/sdk/
COPY packages/protocol/package.json /temp/prod/packages/protocol/
COPY scripts/package.json /temp/prod/scripts/
RUN cd /temp/prod && bun install --frozen-lockfile --production

# Build stage.
FROM base AS build
COPY --from=development-dependencies /temp/dev/node_modules node_modules
COPY package.json bun.lock bunfig.toml ./
COPY admin/package.json ./admin/package.json
COPY server/package.json ./server/package.json
COPY server/packages/email-preview/package.json ./server/packages/email-preview/package.json
COPY server/packages/email-templates/package.json ./server/packages/email-templates/package.json
COPY web/package.json ./web/package.json
COPY web/packages/auth/package.json ./web/packages/auth/package.json
COPY web/packages/client/package.json ./web/packages/client/package.json
COPY web/packages/config/package.json ./web/packages/config/package.json
COPY web/packages/log/package.json ./web/packages/log/package.json
COPY web/packages/protocol/package.json ./web/packages/protocol/package.json
COPY packages/bot-api-types/package.json ./packages/bot-api-types/package.json
COPY packages/bot-api/package.json ./packages/bot-api/package.json
COPY packages/mcp ./packages/mcp
COPY packages/oauth-core ./packages/oauth-core
COPY packages/openclaw-inline/package.json ./packages/openclaw-inline/package.json
COPY packages/sdk ./packages/sdk
COPY packages/protocol ./packages/protocol
COPY scripts/package.json ./scripts/package.json
RUN cd packages/protocol && bun run build
RUN cd packages/sdk && bun run build
RUN cd packages/oauth-core && bun run build
RUN cd packages/mcp && bun run build

# Final stage.
FROM base AS release
COPY --from=production-dependencies /temp/prod/node_modules node_modules
COPY --from=build /usr/src/app/package.json .
COPY --from=build /usr/src/app/bun.lock .
COPY --from=build /usr/src/app/admin/package.json ./admin/package.json
COPY --from=build /usr/src/app/server/package.json ./server/package.json
COPY --from=build /usr/src/app/server/packages/email-preview/package.json ./server/packages/email-preview/package.json
COPY --from=build /usr/src/app/server/packages/email-templates/package.json ./server/packages/email-templates/package.json
COPY --from=build /usr/src/app/web/package.json ./web/package.json
COPY --from=build /usr/src/app/web/packages/auth/package.json ./web/packages/auth/package.json
COPY --from=build /usr/src/app/web/packages/client/package.json ./web/packages/client/package.json
COPY --from=build /usr/src/app/web/packages/config/package.json ./web/packages/config/package.json
COPY --from=build /usr/src/app/web/packages/log/package.json ./web/packages/log/package.json
COPY --from=build /usr/src/app/web/packages/protocol/package.json ./web/packages/protocol/package.json
COPY --from=build /usr/src/app/packages/bot-api-types/package.json ./packages/bot-api-types/package.json
COPY --from=build /usr/src/app/packages/bot-api/package.json ./packages/bot-api/package.json
COPY --from=build /usr/src/app/packages/mcp/package.json ./packages/mcp/package.json
COPY --from=build /usr/src/app/packages/mcp/dist ./packages/mcp/dist
COPY --from=build /usr/src/app/packages/oauth-core/package.json ./packages/oauth-core/package.json
COPY --from=build /usr/src/app/packages/oauth-core/dist ./packages/oauth-core/dist
COPY --from=build /usr/src/app/packages/openclaw-inline/package.json ./packages/openclaw-inline/package.json
COPY --from=build /usr/src/app/packages/sdk/package.json ./packages/sdk/package.json
COPY --from=build /usr/src/app/packages/sdk/dist ./packages/sdk/dist
COPY --from=build /usr/src/app/packages/protocol/package.json ./packages/protocol/package.json
COPY --from=build /usr/src/app/packages/protocol/dist ./packages/protocol/dist
COPY --from=build /usr/src/app/scripts/package.json ./scripts/package.json
RUN bun install --frozen-lockfile --production

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
