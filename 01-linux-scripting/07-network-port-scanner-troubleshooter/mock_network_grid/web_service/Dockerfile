FROM nginx:1.27-alpine

RUN apk add --no-cache curl

COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 80 8080

CMD ["nginx", "-g", "daemon off;"]
