# syntax=docker/dockerfile:1.7
# use the official Bun image
# see all versions at https://hub.docker.com/r/oven/bun/tags
FROM oven/bun:1 AS base
WORKDIR /usr/src/app

# install dependencies into temp directory
# this will cache them and speed up future builds
FROM base AS install
RUN mkdir -p /temp/dev
COPY package.json bun.lock /temp/dev/
COPY admin/package.json /temp/dev/admin/
COPY web/package.json /temp/dev/web/
COPY desktop/package.json /temp/dev/desktop/
COPY scripts/package.json /temp/dev/scripts/
COPY server/package.json /temp/dev/server/
COPY --parents web/packages/*/package.json /temp/dev/
COPY --parents server/packages/*/package.json /temp/dev/
RUN cd /temp/dev && bun install --frozen-lockfile

# install with --production (exclude devDependencies)
RUN mkdir -p /temp/prod
COPY package.json bun.lock /temp/prod/
COPY admin/package.json /temp/prod/admin/
COPY web/package.json /temp/prod/web/
COPY desktop/package.json /temp/prod/desktop/
COPY scripts/package.json /temp/prod/scripts/
COPY server/package.json /temp/prod/server/
COPY --parents web/packages/*/package.json /temp/prod/
COPY --parents server/packages/*/package.json /temp/prod/
RUN cd /temp/prod && bun install --frozen-lockfile --production

# copy node_modules from temp directory
# then copy all (non-ignored) project files into the image
FROM base AS prerelease
COPY --from=install /temp/dev/node_modules node_modules
COPY . .

# Env
ARG SOURCE_COMMIT
ENV SOURCE_COMMIT=${SOURCE_COMMIT}

ARG DATABASE_URL
ENV DATABASE_URL=${DATABASE_URL}

# [optional] tests & build
ENV NODE_ENV=production
# RUN bun typecheck 
RUN bun install --frozen-lockfile 
RUN cd server && bun run build

# copy production dependencies and source code into final image
FROM base AS release
COPY --from=install /temp/prod/node_modules node_modules
COPY --from=prerelease /usr/src/app/server/dist ./server/dist
COPY --from=prerelease /usr/src/app/admin/package.json ./admin/
COPY --from=prerelease /usr/src/app/server/package.json ./server/package.json
COPY --from=prerelease /usr/src/app/package.json .
COPY --from=prerelease /usr/src/app/bun.lock .
COPY --from=prerelease /usr/src/app/web/package.json ./web/
COPY --from=prerelease /usr/src/app/desktop/package.json ./desktop/
COPY --from=prerelease /usr/src/app/scripts/package.json ./scripts/
COPY --from=prerelease /usr/src/app/server/package.json ./server/
COPY --parents web/packages/*/package.json ./
COPY --parents server/packages/*/package.json ./
RUN bun install --frozen-lockfile --production

# Install curl for Coolify healthcheck
RUN apt-get update && apt-get install -y curl


# run the app
USER bun
EXPOSE 8000/tcp

# Add healthcheck
# HEALTHCHECK --interval=10s --timeout=30s --start-period=5s --retries=3 \
#   CMD curl -f http://localhost:8000/ || exit 1

ENTRYPOINT [ "bun", "run", "server/dist/index.js" ]
