FROM node:25-alpine@sha256:bdf2cca6fe3dabd014ea60163eca3f0f7015fbd5c7ee1b0e9ccb4ced6eb02ef4 AS base
# Pin the fixed OpenSSL packages until the upstream image includes this patch.
RUN apk add --no-cache libcrypto3=3.5.8-r0 libssl3=3.5.8-r0

FROM base AS dependencies
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

FROM base
# npm and yarn are build tools; the application runs directly with node.
RUN rm -rf /usr/local/lib/node_modules/npm /opt/yarn-* /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/yarn /usr/local/bin/yarnpkg
ENV NODE_ENV=production
WORKDIR /app
COPY --from=dependencies /app/node_modules ./node_modules
COPY src ./src
COPY package.json ./
USER 1000:1000
EXPOSE 3000
CMD ["node", "src/server.js"]
