FROM python:3.12-alpine

WORKDIR /app

# Copy application files
COPY rbac_policy.json /app/rbac_policy.json
COPY chatops_bot.py /app/chatops_bot.py

EXPOSE 8088

ENV PYTHONUNBUFFERED=1
ENV PORT=8088
ENV HOST=0.0.0.0
ENV SLACK_SIGNING_SECRET=supersecret_slack_signing_token_123
ENV RBAC_FILE=/app/rbac_policy.json
ENV STATE_FILE=/app/.tmp_sandbox/bot_state.json

RUN chmod +x /app/chatops_bot.py

CMD ["python3", "/app/chatops_bot.py"]
