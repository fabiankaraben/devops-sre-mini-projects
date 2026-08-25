FROM python:3.12-alpine

WORKDIR /app

COPY mock_db.py /app/mock_db.py
RUN chmod +x /app/mock_db.py

EXPOSE 5432 6379

CMD ["python3", "-u", "/app/mock_db.py"]
