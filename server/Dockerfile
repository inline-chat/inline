# use the official Bun image
# see all versions at https://hub.docker.com/r/oven/bun/tags
FROM oven/bun:1 AS base
WORKDIR /usr/src/app

# install dependencies into temp directories keyed only by workspace manifests
FROM base AS install
RUN mkdir -p /temp/dev
COPY package.json bun.lock /temp/dev/
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

# copy the preinstalled workspace skeleton, then overlay source code
FROM base AS prerelease
COPY --from=install /temp/dev/ ./
COPY . .

# Env
ARG SOURCE_COMMIT
ENV SOURCE_COMMIT=${SOURCE_COMMIT}

ARG DATABASE_URL
ENV DATABASE_URL=${DATABASE_URL}

# [optional] tests & build
ENV NODE_ENV=production
# RUN bun typecheck 
RUN cd packages/protocol && bun run build
RUN cd packages/oauth-core && bun run build
RUN cd server && bun run build

# copy production dependencies and built artifacts into final image
FROM base AS release
COPY --from=install /temp/prod/ ./
COPY --from=prerelease /usr/src/app/server/dist ./server/dist
COPY --from=prerelease /usr/src/app/packages/oauth-core/dist ./packages/oauth-core/dist
COPY --from=prerelease /usr/src/app/packages/protocol/dist ./packages/protocol/dist

# Install curl/wget for external platform health checks
RUN apt-get update && apt-get install -y --no-install-recommends curl wget && rm -rf /var/lib/apt/lists/*


# run the app
USER bun
EXPOSE 8000/tcp

HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
  CMD sh -c 'curl -fsS "http://127.0.0.1:${PORT:-8000}/healthz" > /dev/null || exit 1'

ENTRYPOINT [ "bun", "run", "server/dist/index.js" ]
