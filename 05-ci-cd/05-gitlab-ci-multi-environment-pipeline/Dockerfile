FROM node:20-alpine AS runtime

WORKDIR /app

# Create unprivileged user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY package.json ./
COPY dist/ ./dist/

USER appuser:appgroup

EXPOSE 8080

CMD ["node", "dist/server.js"]
