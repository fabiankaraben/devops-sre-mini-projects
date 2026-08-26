FROM node:20-alpine

WORKDIR /usr/src/app

COPY package.json ./
COPY server.js ./

EXPOSE 3000

ENV PORT=3000
ENV NODE_ENV=production

CMD ["node", "server.js"]
