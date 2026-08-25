FROM nginx:1.27-alpine

# Install OpenSSL, Bash, and curl for certificate generation and healthchecks
RUN apk add --no-cache bash openssl curl

# Create certs directory
RUN mkdir -p /etc/nginx/certs

# Copy nginx config
COPY nginx.conf /etc/nginx/nginx.conf

# Copy cert generation script and entrypoint
COPY generate_certs.sh /usr/local/bin/generate_certs.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/generate_certs.sh /usr/local/bin/entrypoint.sh

# Pre-generate certificates during image build
RUN /usr/local/bin/generate_certs.sh /etc/nginx/certs

EXPOSE 8443 8444 8445

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
