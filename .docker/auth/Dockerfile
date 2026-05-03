# Build
FROM node:22-alpine AS builder

WORKDIR /app

COPY backend/src/modules/Workers/AuthServer/frontend/package*.json ./
RUN npm ci

COPY backend/src/modules/Workers/AuthServer/frontend/ .
RUN npm run build

# Run
FROM nginx:stable-alpine

COPY --from=builder /app/dist /usr/share/nginx/html
COPY .docker/auth/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 3000
