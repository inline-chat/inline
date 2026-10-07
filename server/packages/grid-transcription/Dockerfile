# Build from the repository root. The worker is separate from the Bun API.
FROM oven/bun:1.4.0 AS build
WORKDIR /app
COPY package.json bun.lock bunfig.toml ./
COPY cli/package.json ./cli/package.json
COPY server ./server
COPY landing ./landing
COPY packages ./packages
COPY plugins ./plugins
COPY scripts ./scripts
RUN bun --no-env-file scripts/docker/prune-workspace.ts @inline-chat/grid-transcription out

FROM node:24-bookworm-slim AS runtime
WORKDIR /app
COPY --from=build /app/out/json/ ./
# Install with Bun using the exact workspace lock, but execute native RTC on Node.
COPY --from=build /usr/local/bin/bun /usr/local/bin/bun
RUN bun --no-env-file install --frozen-lockfile --filter @inline-chat/grid-transcription --linker hoisted
COPY --from=build /app/out/full/ ./
RUN cd server/packages/grid-transcription && bun --no-env-file run build
ENV NODE_ENV=production
USER node
STOPSIGNAL SIGTERM
CMD ["node", "server/packages/grid-transcription/dist/daemon.js"]
