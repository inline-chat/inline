FROM oven/bun:1 AS base
WORKDIR /usr/src/app

FROM base AS pruner
COPY package.json bun.lock bunfig.toml ./
COPY server ./server
COPY web ./web
COPY packages ./packages
COPY scripts ./scripts
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

ARG DATABASE_URL
ENV DATABASE_URL=${DATABASE_URL}

ENV NODE_ENV=production
RUN cd packages/protocol && bun run build
RUN cd packages/oauth-core && bun run build
RUN cd server && bun run build

FROM base AS release
COPY --from=production-dependencies /usr/src/app/ ./
COPY --from=build /usr/src/app/server/dist ./server/dist
COPY --from=build /usr/src/app/packages/oauth-core/dist ./packages/oauth-core/dist
COPY --from=build /usr/src/app/packages/protocol/dist ./packages/protocol/dist

RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

USER bun
EXPOSE 8000/tcp

ENTRYPOINT [ "bun", "run", "server/dist/index.js" ]
