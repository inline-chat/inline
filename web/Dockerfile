FROM oven/bun:1 AS base
WORKDIR /usr/src/app

# Install dependencies into temp directory with devDependencies
FROM base AS development-dependencies
RUN mkdir -p /temp/dev
COPY package.json bun.lockb /temp/dev/
RUN cd /temp/dev && bun install --frozen-lockfile

# Install production dependencies only
FROM base AS production-dependencies
RUN mkdir -p /temp/prod
COPY package.json bun.lockb /temp/prod/
RUN cd /temp/prod && bun install --frozen-lockfile --production

# Build stage
FROM base AS build
COPY --from=development-dependencies /temp/dev/node_modules node_modules
COPY . .
RUN bun run build

# Final stage
FROM base AS release
COPY --from=production-dependencies /temp/prod/node_modules node_modules
COPY --from=build /usr/src/app/build build
COPY package.json .
USER bun
CMD ["bun", "run", "start"]
