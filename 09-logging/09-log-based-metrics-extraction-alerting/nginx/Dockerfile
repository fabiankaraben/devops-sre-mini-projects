FROM nginx:alpine

# Unlink default symlinks to stdout/stderr so Nginx writes to real shared log files
RUN rm -f /var/log/nginx/access.log /var/log/nginx/error.log && \
    mkdir -p /var/log/nginx && \
    touch /var/log/nginx/access.log /var/log/nginx/error.log && \
    chmod 777 /var/log/nginx /var/log/nginx/access.log /var/log/nginx/error.log

COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
