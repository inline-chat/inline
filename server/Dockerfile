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
COPY web/packages/auth/package.json /temp/dev/web/packages/auth/
COPY web/packages/client/package.json /temp/dev/web/packages/client/
COPY web/packages/config/package.json /temp/dev/web/packages/config/
COPY web/packages/log/package.json /temp/dev/web/packages/log/
COPY web/packages/protocol/package.json /temp/dev/web/packages/protocol/
COPY packages/bot-api-types/package.json /temp/dev/packages/bot-api-types/
COPY packages/bot-api/package.json /temp/dev/packages/bot-api/
COPY packages/mcp/package.json /temp/dev/packages/mcp/
COPY packages/oauth-core/package.json /temp/dev/packages/oauth-core/
COPY packages/openclaw-inline/package.json /temp/dev/packages/openclaw-inline/
COPY packages/protocol/package.json /temp/dev/packages/protocol/
COPY packages/sdk/package.json /temp/dev/packages/sdk/
COPY desktop/package.json /temp/dev/desktop/
COPY scripts/package.json /temp/dev/scripts/
COPY server/package.json /temp/dev/server/
COPY server/packages/email-preview/package.json /temp/dev/server/packages/email-preview/
COPY server/packages/email-templates/package.json /temp/dev/server/packages/email-templates/
RUN cd /temp/dev && bun install --frozen-lockfile

# install with --production (exclude devDependencies)
RUN mkdir -p /temp/prod
COPY package.json bun.lock /temp/prod/
COPY admin/package.json /temp/prod/admin/
COPY web/package.json /temp/prod/web/
COPY web/packages/auth/package.json /temp/prod/web/packages/auth/
COPY web/packages/client/package.json /temp/prod/web/packages/client/
COPY web/packages/config/package.json /temp/prod/web/packages/config/
COPY web/packages/log/package.json /temp/prod/web/packages/log/
COPY web/packages/protocol/package.json /temp/prod/web/packages/protocol/
COPY packages/bot-api-types/package.json /temp/prod/packages/bot-api-types/
COPY packages/bot-api/package.json /temp/prod/packages/bot-api/
COPY packages/mcp/package.json /temp/prod/packages/mcp/
COPY packages/oauth-core/package.json /temp/prod/packages/oauth-core/
COPY packages/openclaw-inline/package.json /temp/prod/packages/openclaw-inline/
COPY packages/protocol/package.json /temp/prod/packages/protocol/
COPY packages/sdk/package.json /temp/prod/packages/sdk/
COPY desktop/package.json /temp/prod/desktop/
COPY scripts/package.json /temp/prod/scripts/
COPY server/package.json /temp/prod/server/
COPY server/packages/email-preview/package.json /temp/prod/server/packages/email-preview/
COPY server/packages/email-templates/package.json /temp/prod/server/packages/email-templates/
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
RUN cd packages/oauth-core && bun run build
RUN cd server && bun run build

# copy production dependencies and source code into final image
FROM base AS release
COPY --from=install /temp/prod/node_modules node_modules
COPY --from=prerelease /usr/src/app/server/dist ./server/dist
COPY --from=prerelease /usr/src/app/package.json .
COPY --from=prerelease /usr/src/app/bun.lock .
COPY --from=prerelease /usr/src/app/admin/package.json ./admin/
COPY --from=prerelease /usr/src/app/web/package.json ./web/
COPY --from=prerelease /usr/src/app/web/packages/auth/package.json ./web/packages/auth/
COPY --from=prerelease /usr/src/app/web/packages/client/package.json ./web/packages/client/
COPY --from=prerelease /usr/src/app/web/packages/config/package.json ./web/packages/config/
COPY --from=prerelease /usr/src/app/web/packages/log/package.json ./web/packages/log/
COPY --from=prerelease /usr/src/app/web/packages/protocol/package.json ./web/packages/protocol/
COPY --from=prerelease /usr/src/app/packages/bot-api-types/package.json ./packages/bot-api-types/
COPY --from=prerelease /usr/src/app/packages/bot-api/package.json ./packages/bot-api/
COPY --from=prerelease /usr/src/app/packages/mcp/package.json ./packages/mcp/
COPY --from=prerelease /usr/src/app/packages/oauth-core/package.json ./packages/oauth-core/
COPY --from=prerelease /usr/src/app/packages/oauth-core/dist ./packages/oauth-core/dist
COPY --from=prerelease /usr/src/app/packages/openclaw-inline/package.json ./packages/openclaw-inline/
COPY --from=prerelease /usr/src/app/packages/protocol/package.json ./packages/protocol/
COPY --from=prerelease /usr/src/app/packages/sdk/package.json ./packages/sdk/
COPY --from=prerelease /usr/src/app/desktop/package.json ./desktop/
COPY --from=prerelease /usr/src/app/scripts/package.json ./scripts/
COPY --from=prerelease /usr/src/app/server/package.json ./server/
COPY --from=prerelease /usr/src/app/server/packages/email-preview/package.json ./server/packages/email-preview/
COPY --from=prerelease /usr/src/app/server/packages/email-templates/package.json ./server/packages/email-templates/
RUN bun install --frozen-lockfile --production

# Install curl for Coolify healthcheck
RUN apt-get update && apt-get install -y curl


# run the app
USER bun
EXPOSE 8000/tcp

HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
  CMD curl -fsS http://localhost:8000/healthz || exit 1

ENTRYPOINT [ "bun", "run", "server/dist/index.js" ]
