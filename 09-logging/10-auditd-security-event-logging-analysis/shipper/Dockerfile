FROM python:3.11-alpine

WORKDIR /app

# Pre-create audit log directory
RUN mkdir -p /var/log/audit && chmod 750 /var/log/audit

COPY audit_siem_shipper.py /app/audit_siem_shipper.py

ENV AUDIT_LOG_PATH=/var/log/audit/audit.log
ENV SIEM_URL=http://siem-dashboard:9099

CMD ["python3", "-u", "/app/audit_siem_shipper.py"]
