# Pinned rather than :lts so a base image change is a deliberate commit.
FROM node:20.18-alpine

WORKDIR /app

# Dependencies first so a source edit does not reinstall them.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src

# Runs as the image's own unprivileged user. The controller writes the
# permissions file and reads certificates; it needs no root.
USER node

CMD ["node", "src/index.js"]
