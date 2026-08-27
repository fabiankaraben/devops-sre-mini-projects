FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt || true

COPY postmortem_generator.py test_generator.py ./
COPY mock_incident_logs/ ./mock_incident_logs/

ENTRYPOINT ["python3", "postmortem_generator.py"]
CMD ["--incident-id", "INC-402", "--format", "all", "--output-dir", "/app/reports"]
