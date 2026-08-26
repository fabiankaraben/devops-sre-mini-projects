FROM docker.elastic.co/logstash/logstash:8.13.4

# Copy Logstash configuration, pipelines, custom Grok patterns, and templates
COPY --chown=logstash:logstash config/logstash.yml /usr/share/logstash/config/logstash.yml
COPY --chown=logstash:logstash config/pipelines.yml /usr/share/logstash/config/pipelines.yml
COPY --chown=logstash:logstash pipeline/ /usr/share/logstash/pipeline/
COPY --chown=logstash:logstash patterns/ /usr/share/logstash/patterns/
COPY --chown=logstash:logstash templates/ /usr/share/logstash/templates/
