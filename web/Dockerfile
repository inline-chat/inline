FROM oven/bun:1 AS base
WORKDIR /usr/src/app

FROM base AS pruner
COPY package.json bun.lock bunfig.toml ./
COPY server ./server
COPY web ./web
COPY packages ./packages
COPY scripts ./scripts
RUN bun scripts/docker/prune-workspace.ts @inline-chat/web out

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
RUN cd packages/protocol && bun run build && cd /usr/src/app/web && bun run build

FROM base AS release
COPY --from=production-dependencies /usr/src/app/ ./
COPY --from=build /usr/src/app/web/.output ./web/.output

RUN apt-get update && apt-get install -y curl

USER bun

WORKDIR /usr/src/app/web
CMD ["bun", "run", "start"]
