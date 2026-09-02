FROM node:24.20.0-alpine3.24 AS builder
WORKDIR /app
COPY package.json ./
RUN npm install --production

FROM node:24.20.0-alpine3.24 AS runner
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY src ./src
COPY package.json ./

USER 1000:1000
EXPOSE 3000
CMD ["npm", "start"]
