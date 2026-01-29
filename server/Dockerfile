# use the official Bun image
# see all versions at https://hub.docker.com/r/oven/bun/tags
FROM oven/bun:1 AS base
WORKDIR /usr/src/app

FROM base AS workspaces
COPY . .
RUN bun scripts/docker-workspace-manifests.ts /tmp/workspaces

# install dependencies into temp directory
# this will cache them and speed up future builds
FROM base AS install
RUN mkdir -p /temp/dev
COPY package.json bun.lock /temp/dev/
COPY --from=workspaces /tmp/workspaces/ /temp/dev/
COPY desktop/package.json /temp/dev/desktop/
RUN cd /temp/dev && bun install --frozen-lockfile

# install with --production (exclude devDependencies)
RUN mkdir -p /temp/prod
COPY package.json bun.lock /temp/prod/
COPY --from=workspaces /tmp/workspaces/ /temp/prod/
COPY desktop/package.json /temp/prod/desktop/
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
COPY --from=workspaces /tmp/workspaces/ ./
COPY --from=prerelease /usr/src/app/package.json .
COPY --from=prerelease /usr/src/app/bun.lock .
COPY --from=prerelease /usr/src/app/desktop/package.json ./desktop/
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
