# Use an official Node.js image
FROM node:24 AS builder

# Create app directory
WORKDIR /usr/src/app

# Copy package.json and install dependencies
COPY package*.json ./
RUN npm install

# Copy the rest of the app
COPY . .

# TS
RUN npm run build

FROM node:24-alpine

# Set working directory for the runtime stage
WORKDIR /usr/src/app

# Copy only production files from the builder stage:
# 1. package.json/package-lock.json (needed for the next npm install)
COPY --from=builder /usr/src/app/package*.json ./

# 2. Re-install dependencies, but ONLY production ones
# This keeps the image small and secure by excluding dev dependencies
RUN npm install --only=production

# 3. Copy the compiled application (your 'dist' folder)
COPY --from=builder /usr/src/app/dist ./dist

# Default command to start the production app
CMD ["node", "dist/index.js"]