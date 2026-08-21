# ==============================================================================
# Nginx Frontend Container with Reverse Proxy Configuration
# ==============================================================================
FROM nginx:1.27-alpine

# Remove default configuration and public files
RUN rm -rf /etc/nginx/conf.d/default.conf /usr/share/nginx/html/*

# Copy custom reverse proxy configuration
COPY nginx.conf /etc/nginx/nginx.conf

# Copy static web assets
COPY public/ /usr/share/nginx/html/

# Expose standard HTTP port
EXPOSE 80

# Native healthcheck probe
HEALTHCHECK --interval=10s --timeout=3s --start-period=3s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://127.0.0.1/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
