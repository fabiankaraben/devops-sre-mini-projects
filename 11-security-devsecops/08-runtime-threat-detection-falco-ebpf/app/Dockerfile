FROM python:3.11-alpine

# Install tools for threat simulation (netcat, bash, curl)
RUN apk add --no-cache bash netcat-openbsd curl busybox-extras

WORKDIR /app

COPY app.py /app/app.py

EXPOSE 8080

CMD ["python3", "/app/app.py"]
