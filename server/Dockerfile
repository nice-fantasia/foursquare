FROM node:24-alpine AS build

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY prisma ./prisma
COPY tsconfig.json tsconfig.production.json ./
COPY src ./src
RUN npm run build:production

FROM build AS migration

ENV NODE_ENV=production
USER node

CMD ["npm", "run", "db:migrate:deploy"]

FROM node:24-alpine AS production-dependencies

WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY --from=build /app/node_modules/.prisma ./node_modules/.prisma

FROM node:24-alpine AS runtime

ENV NODE_ENV=production
ENV PORT=3000
WORKDIR /app

COPY --from=production-dependencies --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist

USER node
EXPOSE 3000
STOPSIGNAL SIGTERM

CMD ["node", "dist/index.js"]
