# Build from the repository root. See docs/fly-container.md for a commit-only context.
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
RUN bun scripts/docker/prune-workspace.ts @inline-chat/server out

FROM base AS development-dependencies
COPY --from=pruner /usr/src/app/out/json/ ./
RUN bun install --frozen-lockfile --filter @inline-chat/server --linker hoisted

FROM base AS production-dependencies
COPY --from=pruner /usr/src/app/out/json/ ./
RUN bun install --frozen-lockfile --filter @inline-chat/server --production --linker hoisted

FROM base AS build
COPY --from=development-dependencies /usr/src/app/ ./
COPY --from=pruner /usr/src/app/out/full/ ./
ARG SOURCE_COMMIT
ENV SOURCE_COMMIT=${SOURCE_COMMIT} NODE_ENV=production
RUN test -n "$SOURCE_COMMIT"
RUN cd packages/protocol && bun run build
RUN cd packages/oauth-core && bun run build
RUN cd server && bun run build

# Shared runtime: one Bun process; migrations are explicit commands.
FROM base AS runtime
ARG SOURCE_COMMIT
LABEL org.opencontainers.image.source="https://github.com/inline-chat/inline" \
      org.opencontainers.image.revision=${SOURCE_COMMIT}
ENV NODE_ENV=production PORT=8000
COPY --from=production-dependencies /usr/src/app/ ./
COPY --from=build /usr/src/app/server/dist ./server/dist
COPY --from=build /usr/src/app/server/drizzle ./server/drizzle
COPY --from=build /usr/src/app/packages/oauth-core/dist ./packages/oauth-core/dist
COPY --from=build /usr/src/app/packages/protocol/dist ./packages/protocol/dist
COPY --from=build /usr/src/app/server/scripts/start-production.ts ./server/scripts/start-production.ts
# Keep existing operational command paths, but resolve their complete import
# graph at build time. No hand-maintained server/src copies in the runtime.
RUN mkdir -p server/scripts && \
    for command in migrate verify-migrations livekit-cutover-preflight; do \
      printf 'import { main } from "../dist/%s.js"; process.exitCode = await main()\n' "$command" > "server/scripts/$command.ts"; \
    done
COPY --from=pruner /usr/src/app/out/full/scripts/docker/smoke-artifact.ts ./scripts/docker/smoke-artifact.ts
USER bun
RUN bun --no-env-file scripts/docker/smoke-artifact.ts server
EXPOSE 8000/tcp
STOPSIGNAL SIGTERM
CMD ["bun", "server/dist/index.js"]

# Existing Coolify builds default to this compatibility target. Fly and other
# platforms use --target runtime. Only Coolify needs its wget health probe shim.
FROM runtime AS coolify
USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl wget && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/src/app/server/scripts/helpers/healthcheck-wget.sh /usr/local/bin/wget
RUN chmod 0755 /usr/local/bin/wget
USER bun
