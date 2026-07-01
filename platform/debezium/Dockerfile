# Kafka Connect image for Debezium CDC (the outbox relay). MUST derive from the Strimzi Kafka image so the
# Strimzi Connect entrypoint + metrics agent are present; we only add the Debezium Postgres connector plugin.
#
# Build + push (prod, ACR):
#   docker build -t labg03clusterregistry.azurecr.io/eurotransit/debezium-connect:1.0.0 platform/debezium
#   docker push  labg03clusterregistry.azurecr.io/eurotransit/debezium-connect:1.0.0
# Kind uses the same Dockerfile via `just debezium-kind-apply` (pushed to localhost:5001).
ARG STRIMZI_VERSION=1.1.0
ARG KAFKA_VERSION=4.3.0
FROM quay.io/strimzi/kafka:${STRIMZI_VERSION}-kafka-${KAFKA_VERSION}

USER root:root

# Debezium Postgres connector: unpack under the Connect plugin.path (each plugin in its own subdir).
ARG DEBEZIUM_VERSION=3.0.0.Final
ADD https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz /tmp/debezium.tar.gz
RUN mkdir -p /opt/kafka/plugins \
    && tar -xzf /tmp/debezium.tar.gz -C /opt/kafka/plugins/ \
    && rm -f /tmp/debezium.tar.gz

# back to the non-root Strimzi runtime user
USER 1001
