# Use an official Node.js image
FROM node:24

# Create app directory
WORKDIR /usr/src/app

# Copy package.json and install dependencies
COPY package*.json ./
RUN npm install

# Copy the rest of the app
COPY . .

# TS
RUN npm run build
# Default command
CMD ["node", "dist/index.js"]