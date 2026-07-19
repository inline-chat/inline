FROM oven/bun:1.3.1 AS base
WORKDIR /usr/src/app

FROM base AS pruner
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
COPY package.json bunfig.toml ./
COPY server ./server
COPY landing ./landing
COPY packages ./packages
COPY scripts ./scripts
ARG INLINE_PUBLIC_REPO
ARG INLINE_PUBLIC_REF
ARG INLINE_PUBLIC_REF_FILE
RUN INLINE_PUBLIC_REQUIRED_MANIFESTS="packages/bot-api/package.json packages/mcp/package.json packages/oauth-core/package.json packages/openclaw/package.json packages/sdk/package.json" bash scripts/ci/ensure-public-workspaces.sh
RUN bun scripts/docker/prune-workspace.ts @inline-chat/server out

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

# Env
ARG SOURCE_COMMIT
ENV SOURCE_COMMIT=${SOURCE_COMMIT}

ENV NODE_ENV=production
RUN cd packages/protocol && bun run build
RUN cd packages/oauth-core && bun run build
RUN cd server && bun run build

FROM base AS release
COPY --from=production-dependencies /usr/src/app/ ./
COPY --from=build /usr/src/app/server/dist ./server/dist
COPY --from=build /usr/src/app/server/drizzle ./server/drizzle
COPY --from=build /usr/src/app/server/scripts/start-production.ts ./server/scripts/start-production.ts
COPY --from=build /usr/src/app/server/scripts/migrate.ts ./server/scripts/migrate.ts
COPY --from=build /usr/src/app/server/scripts/helpers ./server/scripts/helpers
COPY --from=build /usr/src/app/packages/oauth-core/dist ./packages/oauth-core/dist
COPY --from=build /usr/src/app/packages/protocol/dist ./packages/protocol/dist

RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production
USER bun
EXPOSE 8000/tcp

ENTRYPOINT [ "bun", "run", "server/scripts/start-production.ts" ]
