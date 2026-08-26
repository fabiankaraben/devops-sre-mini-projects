FROM timberio/vector:0.41.0-alpine

# Copy configuration file
COPY config/vector.toml /etc/vector/vector.toml

# Create output log directory with appropriate permissions
RUN mkdir -p /var/log/vector && chmod 777 /var/log/vector

# Expose HTTP (:8080), TCP Socket (:9000), and API (:8686)
EXPOSE 8080 9000 8686

CMD ["--config", "/etc/vector/vector.toml"]
