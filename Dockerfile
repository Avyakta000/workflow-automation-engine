FROM node:18-alpine

WORKDIR /app

# Copy package files
COPY package*.json ./
COPY tsconfig.json ./

# Install dependencies
RUN npm ci --only=production

# Copy source
COPY lib/ ./lib/
COPY workers/ ./workers/
COPY worker.ts ./

# Build
RUN npm run build

# Run worker
CMD ["npm", "start"]
