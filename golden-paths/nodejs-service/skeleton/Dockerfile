FROM node:18-alpine AS builder
WORKDIR /app
COPY package.json ./
RUN npm install --production

FROM node:18-alpine AS runner
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY src ./src
COPY package.json ./

USER node
EXPOSE 3000
CMD ["npm", "start"]
