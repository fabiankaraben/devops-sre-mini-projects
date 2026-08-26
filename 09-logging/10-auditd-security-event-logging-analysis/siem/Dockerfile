FROM python:3.11-alpine

WORKDIR /app

COPY siem_server.py /app/siem_server.py
COPY templates/ /app/templates/

EXPOSE 9099

HEALTHCHECK --interval=3s --timeout=3s --retries=20 --start-period=3s \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9099/api/health')" || exit 1

CMD ["python3", "siem_server.py", "9099"]
