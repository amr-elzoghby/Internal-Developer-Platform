
FROM node:18-bullseye-slim AS packages

WORKDIR /app
COPY package.json yarn.lock ./
COPY packages packages
COPY plugins plugins

FROM node:18-bullseye-slim AS build

WORKDIR /app
COPY --from=packages /app .
COPY . .

RUN yarn install --frozen-lockfile
RUN yarn tsc
RUN yarn build:backend

FROM node:18-bullseye-slim AS runner

WORKDIR /app

ENV NODE_ENV=production

COPY --from=build /app/development.sqlite ./
COPY --from=build /app/packages/backend/dist/bundle.tar.gz ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz
COPY --from=build /app/app-config.yaml ./

EXPOSE 7007

CMD ["node", "packages/backend", "--config", "app-config.yaml"]
