FROM oven/bun:1 AS base
WORKDIR /usr/src/app

# Install dependencies into temp directory with devDependencies
FROM base AS development-dependencies
RUN mkdir -p /temp/dev
COPY package.json bun.lock /temp/dev/
COPY admin/package.json /temp/dev/admin/
COPY server/package.json /temp/dev/server/
COPY web/package.json /temp/dev/web/
COPY web/packages/auth/package.json /temp/dev/web/packages/auth/
COPY web/packages/client/package.json /temp/dev/web/packages/client/
COPY web/packages/config/package.json /temp/dev/web/packages/config/
COPY web/packages/log/package.json /temp/dev/web/packages/log/
COPY web/packages/protocol/package.json /temp/dev/web/packages/protocol/
COPY scripts/package.json /temp/dev/scripts/
RUN cd /temp/dev && bun install --frozen-lockfile

# Install production dependencies only
FROM base AS production-dependencies
RUN mkdir -p /temp/prod
COPY package.json bun.lock /temp/prod/
COPY admin/package.json /temp/prod/admin/
COPY server/package.json /temp/prod/server/
COPY web/package.json /temp/prod/web/
COPY web/packages/auth/package.json /temp/prod/web/packages/auth/
COPY web/packages/client/package.json /temp/prod/web/packages/client/
COPY web/packages/config/package.json /temp/prod/web/packages/config/
COPY web/packages/log/package.json /temp/prod/web/packages/log/
COPY web/packages/protocol/package.json /temp/prod/web/packages/protocol/
COPY scripts/package.json /temp/prod/scripts/
RUN cd /temp/prod && bun install --frozen-lockfile --production

# Build stage
FROM base AS build
COPY --from=development-dependencies /temp/dev/node_modules node_modules
COPY . .
RUN cd admin && bun run build

# Final stage
FROM base AS release
COPY --from=production-dependencies /temp/prod/node_modules node_modules
COPY --from=build /usr/src/app/admin/dist ./admin/dist
COPY --from=build /usr/src/app/admin/serve.ts ./admin/serve.ts
COPY --from=build /usr/src/app/admin/package.json ./admin/package.json
COPY --from=build /usr/src/app/package.json .
COPY --from=build /usr/src/app/bun.lock .

# Install curl for Coolify healthcheck
RUN apt-get update && apt-get install -y curl

USER bun

WORKDIR /usr/src/app/admin
CMD ["bun", "run", "start"]
