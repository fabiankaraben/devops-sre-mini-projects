FROM python:3.11-alpine

WORKDIR /app

COPY graceful_server.py load_tester.py ./

EXPOSE 8080

ENTRYPOINT ["python3", "-u", "graceful_server.py"]
CMD ["--port", "8080", "--mode", "graceful", "--grace-timeout", "15.0", "--work-delay-ms", "250.0"]
