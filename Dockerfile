# Cloud Run image for the agent-native "plan" template (full Node server).
#
# Build context MUST be the repo root — this is a pnpm monorepo and the build
# needs the workspace packages (@agent-native/core, etc.).
#
# Deploy:  gcloud run deploy plan --source .   (uses this root Dockerfile)
#
# Plan runs unmodified here: the default Nitro preset is `node`, which emits a
# standalone server at templates/plan/.output/server/index.mjs. No Workers
# bundle/startup limits, native modules (better-sqlite3, etc.) compile in-image.

# ---- Build stage ----
FROM node:22-bookworm-slim AS build
RUN corepack enable
# Toolchain for any native module builds (e.g. better-sqlite3).
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
RUN pnpm install --frozen-lockfile
RUN pnpm --filter @agent-native/core build
# No NITRO_PRESET → default "node" preset → .output/server/index.mjs
RUN pnpm --filter plan build

# ---- Runtime stage ----
FROM node:22-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
# Nitro's node-server .output is self-contained (server + bundled deps + public).
COPY --from=build /app/templates/plan/.output ./.output
# Cloud Run injects PORT (default 8080); Nitro's node server honors it.
ENV PORT=8080
EXPOSE 8080
CMD ["node", ".output/server/index.mjs"]
