FROM python:3.12-alpine

WORKDIR /app

COPY proxy_server.py /app/proxy_server.py

RUN chmod +x /app/proxy_server.py

EXPOSE 8090

ENV PORT=8090
ENV HOST=0.0.0.0
ENV PYTHONUNBUFFERED=1

CMD ["python3", "/app/proxy_server.py"]
