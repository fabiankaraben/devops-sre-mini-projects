# ==============================================================================
# Alertmanager Container Image
# ==============================================================================

FROM prom/alertmanager:v0.27.0

LABEL maintainer="DevOps & SRE Mini Projects"
LABEL description="Alertmanager server with routing trees and inhibition rules"

COPY alertmanager.yml /etc/alertmanager/alertmanager.yml

WORKDIR /alertmanager
VOLUME [ "/alertmanager" ]
EXPOSE 9093
