FROM node:26.8.2-bookworm-slim AS build-node

FROM oven/bun:1.4.0 AS base
WORKDIR /usr/src/app

FROM base AS pruner
COPY package.json bun.lock bunfig.toml ./
COPY cli/package.json ./cli/package.json
COPY server ./server
COPY landing ./landing
COPY packages ./packages
COPY plugins ./plugins
COPY scripts ./scripts
RUN bun scripts/docker/prune-workspace.ts @inline-chat/landing out

FROM base AS development-dependencies
COPY --from=pruner /usr/src/app/out/json/ ./
RUN bun install --frozen-lockfile --filter @inline-chat/landing

FROM base AS production-dependencies
COPY --from=pruner /usr/src/app/out/json/ ./
RUN bun install --frozen-lockfile --filter @inline-chat/landing --production

FROM base AS build
# StyleX compilation currently fails under Bun; match the Node-backed CI compiler.
COPY --from=build-node /usr/local/bin/node /usr/local/bin/node
COPY --from=development-dependencies /usr/src/app/ ./
COPY --from=pruner /usr/src/app/out/full/ ./
RUN cd packages/protocol && bun run build && cd /usr/src/app/landing && bun run build

FROM base AS release
COPY --from=production-dependencies /usr/src/app/ ./
COPY --from=build /usr/src/app/landing/.output ./landing/.output

RUN apt-get update && apt-get install -y curl

COPY --from=pruner /usr/src/app/out/full/scripts/docker/smoke-artifact.ts ./scripts/docker/smoke-artifact.ts
USER bun
RUN bun scripts/docker/smoke-artifact.ts landing

ENV NODE_ENV=production
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 \
  CMD bun -e "fetch('http://127.0.0.1:3000/').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"
WORKDIR /usr/src/app/landing
CMD ["bun", "run", "start"]
