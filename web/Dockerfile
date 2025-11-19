FROM oven/bun:1 AS base
WORKDIR /usr/src/app

# Install dependencies into temp directory with devDependencies
FROM base AS development-dependencies
RUN mkdir -p /temp/dev
COPY package.json bun.lock /temp/dev/
COPY web/package.json /temp/dev/web/
COPY server/package.json /temp/dev/server/
COPY scripts/package.json /temp/dev/scripts/
RUN cd /temp/dev && bun install --frozen-lockfile

# Install production dependencies only
FROM base AS production-dependencies
RUN mkdir -p /temp/prod
COPY package.json bun.lock /temp/prod/
COPY web/package.json /temp/prod/web/
COPY server/package.json /temp/prod/server/
COPY scripts/package.json /temp/prod/scripts/
RUN cd /temp/prod && bun install --frozen-lockfile --production

# Build stage
FROM base AS build
COPY --from=development-dependencies /temp/dev/node_modules node_modules
COPY . .
RUN cd web && bun run build

# Final stage
FROM base AS release
COPY --from=production-dependencies /temp/prod/node_modules node_modules
COPY --from=build /usr/src/app/web/.output ./web/.output
COPY --from=build /usr/src/app/web/package.json ./web/package.json
COPY package.json .

# Install curl for Coolify healthcheck
RUN apt-get update && apt-get install -y curlƒ

USER bun

WORKDIR /usr/src/app/web
CMD ["bun", "run", "start"]
