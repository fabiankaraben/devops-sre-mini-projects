FROM prom/alertmanager:v0.27.0

COPY alertmanager.yml /etc/alertmanager/alertmanager.yml

EXPOSE 9093

CMD ["--config.file=/etc/alertmanager/alertmanager.yml", \
     "--storage.path=/alertmanager", \
     "--web.listen-address=0.0.0.0:9093"]
