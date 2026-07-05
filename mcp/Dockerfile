FROM oven/bun:1.3.1 AS base
WORKDIR /app

FROM base AS deps
COPY package.json bun.lock bunfig.toml ./
COPY proto ./proto
COPY cli ./cli
COPY packages ./packages
COPY sdk ./sdk
COPY mcp ./mcp
COPY openclaw ./openclaw
COPY hermes-agent ./hermes-agent
RUN bun install --frozen-lockfile

FROM deps AS build
RUN bun run --cwd packages/protocol build
RUN bun run --cwd packages/oauth-core build
RUN bun run --cwd sdk build
RUN bun run --cwd mcp build

FROM base AS release
COPY package.json bun.lock bunfig.toml ./
COPY proto ./proto
COPY cli ./cli
COPY packages ./packages
COPY sdk ./sdk
COPY mcp ./mcp
COPY openclaw ./openclaw
COPY hermes-agent ./hermes-agent
RUN bun install --frozen-lockfile --production
COPY --from=build /app/packages/protocol/dist ./packages/protocol/dist
COPY --from=build /app/packages/oauth-core/dist ./packages/oauth-core/dist
COPY --from=build /app/sdk/dist ./sdk/dist
COPY --from=build /app/mcp/dist ./mcp/dist

ENV NODE_ENV=production
ENV PORT=8791

USER bun
WORKDIR /app/mcp
EXPOSE 8791

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD bun -e "const port = process.env.PORT || '8791'; fetch('http://127.0.0.1:' + port + '/health', { headers: { Host: 'mcp.inline.chat' } }).then((res) => process.exit(res.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["bun", "run", "dist/main.js"]
