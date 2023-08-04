# Preface

When your application has customers all over the world and you want to decrease the latency for them, usually you 
deploy instances of your application in different DC.

We also do so, we have clusters deployed in US and UK.

Each of our clusters has its own kafka cluster. We use it to collect realtime logs from all nodes. Later logs are 
consumed by Graylog, analytics processors and alerting system.

The tricky part here is to manage all the clusters in each application, that consumes the messages (so, graylog will 
be aware of UK and US clusters and will connect to both). No one wants that. The much better idea is to have 
centralized kafka cluster, where we can get logs from all remote DC.

This is where mirror maker comes in play. The idea of this application is to read the messages from remote 
kafka cluster and write them into local cluster.

Previously we used mirror maker 1, which literally consisted of consumers per each source cluster and producers 
per each target cluster. It works pretty well, and even has some advantages over mirror maker 2 (e.g., you can 
control the number of partitions in target cluster). But time goes on, we decided to migrate to mm2.

MM2 can run in 3 main modes (https://cwiki.apache.org/confluence/display/KAFKA/KIP-382%3A+MirrorMaker+2.0#KIP382:MirrorMaker2.0-Walkthrough:RunningMirrorMaker2.0):
- Legacy mode (much the same as mm1)
- Standalone/distributed mode with some limitations:
    https://cwiki.apache.org/confluence/display/KAFKA/KIP-710%3A+Full+support+for+distributed+mode+in+dedicated+MirrorMaker+2.0+clusters
- Inside kafka connect cluster

We are going to deploy mm2 inside kafka connect cluster. We will create configuration for the worker, 
monitor workers using kafka.


# Initial setup

Let’s start with 2 clusters and helper application:
- Source cluster (2 nodes)
- Target cluster (2 nodes)
- Kafka ui
- Kafka exporter
- Prometheus
- Grafana

For the details of this deployment, please read my previous article:
https://medium.com/@penkov.vladimir/kafka-cluster-with-ui-and-metrics-easy-setup-d12d1b94eccf.

The `docker-compose.yml` config will be like this:

```yaml
version: '3.8'

x-kafka-common: &kafka-common
  image: 'bitnami/kafka:latest'
  ports:
    - "9092"
  networks:
    - kafka
  healthcheck:
    test: "bash -c 'printf \"\" > /dev/tcp/127.0.0.1/9092; exit $$?;'"
    interval: 5s
    timeout: 10s
    retries: 3
    start_period: 30s
  restart: unless-stopped




x-kafka-source-env-common: &kafka-source-env-common
  ALLOW_PLAINTEXT_LISTENER: 'yes'
  KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE: 'true'
  KAFKA_CFG_CONTROLLER_QUORUM_VOTERS: 0@kafka-source-0:9093,1@kafka-source-1:9093
  KAFKA_KRAFT_CLUSTER_ID: abcdefghijklmnopqrstuv
  KAFKA_CFG_PROCESS_ROLES: controller,broker
  KAFKA_CFG_CONTROLLER_LISTENER_NAMES: CONTROLLER
  KAFKA_CFG_LISTENERS: PLAINTEXT://:9092,CONTROLLER://:9093
  EXTRA_ARGS: "-Xms128m -Xmx256m -javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-0.19.0.jar=9404:/opt/jmx-exporter/kafka-2_0_0.yml"


x-kafka-target-env-common: &kafka-target-env-common
  ALLOW_PLAINTEXT_LISTENER: 'yes'
  KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE: 'true'
  KAFKA_CFG_CONTROLLER_QUORUM_VOTERS: 0@kafka-target-0:9093,1@kafka-target-1:9093
  KAFKA_KRAFT_CLUSTER_ID: abcdef123jklmnopqrstuv
  KAFKA_CFG_PROCESS_ROLES: controller,broker
  KAFKA_CFG_CONTROLLER_LISTENER_NAMES: CONTROLLER
  KAFKA_CFG_LISTENERS: PLAINTEXT://:9092,CONTROLLER://:9093
  EXTRA_ARGS: "-Xms128m -Xmx256m -javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-0.19.0.jar=9404:/opt/jmx-exporter/kafka-2_0_0.yml"


services:

  kafka-source-0:
    <<: *kafka-common
    environment:
      <<: *kafka-source-env-common
      KAFKA_CFG_NODE_ID: 0
    volumes:
      - kafka_0_data:/bitnami/kafka
      - ./jmx-exporter:/opt/jmx-exporter

  kafka-source-1:
    <<: *kafka-common
    environment:
      <<: *kafka-source-env-common
      KAFKA_CFG_NODE_ID: 1
    volumes:
      - kafka_1_data:/bitnami/kafka
      - ./jmx-exporter:/opt/jmx-exporter

  kafka-target-0:
    <<: *kafka-common
    environment:
      <<: *kafka-target-env-common
      KAFKA_CFG_NODE_ID: 0
    volumes:
      - kafka_2_data:/bitnami/kafka
      - ./jmx-exporter:/opt/jmx-exporter

  kafka-target-1:
    <<: *kafka-common
    environment:
      <<: *kafka-target-env-common
      KAFKA_CFG_NODE_ID: 1
    volumes:
      - kafka_3_data:/bitnami/kafka
      - ./jmx-exporter:/opt/jmx-exporter


  kafka-ui:
    container_name: kafka-ui
    image: provectuslabs/kafka-ui:latest
    volumes:
      - ./kafka-ui/config.yml:/etc/kafkaui/dynamic_config.yaml
    environment:
      DYNAMIC_CONFIG_ENABLED: 'true'
    depends_on:
      kafka-source-0:
        condition: service_healthy
      kafka-source-1:
        condition: service_healthy
      kafka-target-0:
        condition: service_healthy
      kafka-target-1:
        condition: service_healthy
    networks:
      - kafka
    ports:
      - '8080:8080'
    healthcheck:
      test: wget --no-verbose --tries=1 --spider localhost:8080 || exit 1
      interval: 5s
      timeout: 10s
      retries: 3
      start_period: 30s

  prometheus:
    image: prom/prometheus
    container_name: prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
    ports:
      - 9090:9090
    volumes:
      - ./prometheus:/etc/prometheus
      - prom_data:/prometheus
    networks:
      - kafka
    healthcheck:
      test: wget --no-verbose --tries=1 --spider localhost:9090 || exit 1
      interval: 5s
      timeout: 10s
      retries: 3
      start_period: 5s


  kafka-exporter:
    image: docker.io/bitnami/kafka-exporter:latest
    depends_on:
      kafka-source-0:
        condition: service_healthy
      kafka-source-1:
        condition: service_healthy
      kafka-target-0:
        condition: service_healthy
      kafka-target-1:
        condition: service_healthy
    ports:
      - "9308:9308"
    networks:
      - kafka
    command: --kafka.server=kafka-source-0:9092 --kafka.server=kafka-source-1:9092 --kafka.server=kafka-target-0:9092 --kafka.server=kafka-target-1:9092
    healthcheck:
      test: "bash -c 'printf \"\" > /dev/tcp/127.0.0.1/9308; exit $$?;'"
      interval: 5s
      timeout: 10s
      retries: 3
      start_period: 5s

  grafana:
    image: grafana/grafana
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=grafana
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/var/lib/grafana/dashboards
    networks:
      - kafka
    healthcheck:
      test: curl --fail localhost:3000
      interval: 5s
      timeout: 10s
      retries: 3
      start_period: 10s



networks:
  kafka:

volumes:
  kafka_0_data:
    driver: local
  kafka_1_data:
    driver: local
  kafka_2_data:
    driver: local
  kafka_3_data:
    driver: local
  prom_data:
    driver: local
```

`kafka-ui/config.yml` should contain:

```yaml
kafka:
  clusters:
    - bootstrapServers: kafka-source-0:9092,kafka-source-1:9092
      name: kafka-source
      metrics:
        type: JMX
        port: 9404

    - bootstrapServers: kafka-target-0:9092,kafka-target-1:9092
      name: kafka-target
      metrics:
        type: JMX
        port: 9404
```

`prometheus/prometheus.yml` should contain:

```yaml
- job_name: kafka-source-exporter
  honor_timestamps: true
  scrape_interval: 15s
  scrape_timeout: 10s
  metrics_path: /metrics
  scheme: http
  static_configs:
    - targets:
        - kafka-source-0:9404
        - kafka-source-1:9404
- job_name: kafka-target-exporter
  honor_timestamps: true
  scrape_interval: 15s
  scrape_timeout: 10s
  metrics_path: /metrics
  scheme: http
  static_configs:
    - targets:
        - kafka-target-0:9404
        - kafka-target-1:9404
```


Let’s start the services:
```shell
docker-compose up
```


Visit Kafka UI at (http://localhost:8080 with credentials  `admin`:`admin`. now we have 2 clusters online. 

Now we need to add new kafka connect cluster.


# Kafka connect

Our connect cluster will consist of 2 nodes. First we define common environment variables:
```yaml
x-kafka-connect-env-common: &kafka-connect-env-common
  KAFKA_HEAP_OPTS: "-Xmx256m -Xms128M -javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-0.19.0.jar=9404:/opt/jmx-exporter/kafka-2_0_0.yml"
```

We will use kafka-target cluster for storing all kafka connect internal data. This makes sense, because 
deployment mm2 close to the target cluster will improve network latency.

Next common properties:
```yaml
x-kafka-connect-common: &kafka-connect-common
  image: 'bitnami/kafka:latest'
  networks:
    - kafka
  volumes:
    - ./jmx-exporter:/opt/jmx-exporter
    - ./kafka-connect/connect-distributed.properties:/opt/bitnami/kafka/config/connect-distributed.properties
  depends_on:
    kafka-target-0:
      condition: service_healthy
    kafka-target-1:
      condition: service_healthy
  command: /opt/bitnami/kafka/bin/connect-distributed.sh /opt/bitnami/kafka/config/connect-distributed.properties
  healthcheck:
    test: "bash -c 'printf \"\" > /dev/tcp/127.0.0.1/8083; exit $$?;'"
    interval: 5s
    timeout: 10s
    retries: 3
    start_period: 30s
  restart: unless-stopped
  environment:
    <<: *kafka-connect-env-common
```


Create configuration file for kafka connect:
```shell
mkdir -p kafka-connect
touch kafka-connect/connect-distributed.properties
```

use the following:
```properties
bootstrap.servers=kafka-target-0:9092,kafka-target-1:9092
group.id=connect-cluster
key.converter=org.apache.kafka.connect.json.JsonConverter
value.converter=org.apache.kafka.connect.json.JsonConverter
key.converter.schemas.enable=true
value.converter.schemas.enable=true
internal.key.converter=org.apache.kafka.connect.json.JsonConverter
internal.value.converter=org.apache.kafka.connect.json.JsonConverter
internal.key.converter.schemas.enable=false
internal.value.converter.schemas.enable=false
offset.storage.topic=connect-offsets
offset.storage.replication.factor=1
#offset.storage.partitions=25
config.storage.topic=connect-configs
config.storage.replication.factor=1
status.storage.topic=connect-status
status.storage.replication.factor=1
offset.flush.interval.ms=10000
rest.port=8083
```


Now let’s add 2 kafka connect nodes:

```yaml
kafka-connect-0:
  <<: *kafka-connect-common
  hostname: kafka-connect-0
  ports:
    - '8083:8083'

kafka-connect-1:
  <<: *kafka-connect-common
  hostname: kafka-connect-1
```


We open 8083 port on 1st instance to be able to deploy connectors configurations with rest endpoints.

Add both nodes to kafka UI in the kafka-target cluster:
```yaml
    - bootstrapServers: kafka-target-0:9092,kafka-target-1:9092
      name: kafka-target
      kafkaConnect:
        - address: http://kafka-connect-0:8083
          name: kafka-connect-0
        - address: http://kafka-connect-1:8083
          name: kafka-connect-1
      metrics:
        type: PROMETHEUS
        port: 9404
```


Add jmx exporters to Prometheus:

```yaml
  - job_name: kafka-connect-exporter
    honor_timestamps: true
    scrape_interval: 15s
    scrape_timeout: 10s
    metrics_path: /metrics
    scheme: http
    static_configs:
      - targets:
          - kafka-connect-0:9404
          - kafka-connect-1:9404
```


Restart docker compose.



Before we starts actual mirror maker 2 connectors, we need to create topic `test` and produce some messages:
```shell
docker compose exec kafka-source-0 /opt/bitnami/kafka/bin/kafka-topics.sh --create \      
   --bootstrap-server kafka-source-0:9092,kafka-source-1:9092 --replication-factor 2 \
   --partitions 5 --topic test
docker compose exec kafka-source-0 /opt/bitnami/kafka/bin/kafka-console-producer.sh \
   --bootstrap-server kafka-source-0:9092,kafka-source-1:9092 \
   --producer.config /opt/bitnami/kafka/config/producer.properties --topic test
```


# Mirror Maker 2 Connectors

Basically we need 3 configuration files:
- The MirrorHeartbeatConnector provides heartbeats, monitoring of replication flows, and 
  client discovery of replication topologies (which can be more complex than for the original MirrorMaker).
- The MirrorCheckpointConnector manages consumer offset synchronization, emits checkpoints, and enables failover.
- The MirrorSourceConnector replicates records from local to remote clusters and enables offset synchronization.
     
More details here: https://www.instaclustr.com/blog/kafka-mirrormaker-2-theory/

We will store the 3 files per each source cluster in the folder mm2 in the format:
- `mm2-cpc-<cluster>.json`
- `mm2-hbc-<cluster>.json`
- `mm2-msc-<cluster>.json`


For example, we have cluster `source-0`, so the files will be:
- `mm2-cpc-source-0.json`
- `mm2-hbc-source-0.json`
- `mm2-msc-source-0.json`

Here are the contents:

`mm2-cpc-source-0.json`:
```json
{
  "name": "mm2-cpc-source-0",
  "connector.class": "org.apache.kafka.connect.mirror.MirrorCheckpointConnector",
  "key.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
  "value.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
  "source.cluster.alias": "source-0",
  "source.cluster.bootstrap.servers": "kafka-source-0:9092,kafka-source-1:9092",
  "target.cluster.alias": "target-0",
  "target.cluster.bootstrap.servers": "kafka-target-0:9092,kafka-target-1:9092"
}
```


`mm2-hbc-source-0.json`:
```json
{
  "name": "mm2-hbc-source-0",
  "connector.class": "org.apache.kafka.connect.mirror.MirrorHeartbeatConnector",
  "key.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
  "value.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
  "source.cluster.alias": "source-0",
  "source.cluster.bootstrap.servers": "kafka-source-0:9092,kafka-source-1:9092",
  "target.cluster.alias": "target-0",
  "target.cluster.bootstrap.servers": "kafka-target-0:9092,kafka-target-1:9092"
}
```


`mm2-msc-source-0.json`:
```json
{
  "name": "mm2-msc-source-0",
  "connector.class": "org.apache.kafka.connect.mirror.MirrorSourceConnector",
  "topics": "test",
  "sync.topic.acls.enabled": false,
  "sync.topic.configs.enabled": false,
  "key.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
  "value.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
  "source.cluster.alias": "source-0",
  "source.cluster.bootstrap.servers": "kafka-source-0:9092,kafka-source-1:9092",
  "target.cluster.alias": "target-0",
  "target.cluster.bootstrap.servers": "kafka-target-0:9092,kafka-target-1:9092",
  "replication.factor": "1",
  "replication.policy.class": "org.apache.kafka.connect.mirror.IdentityReplicationPolicy",
  "tasks.max": "2"
}
```


Here I disable `sync.topic.acls.enabled` and `sync.topic.configs.enabled`. The reason was explained here: 
https://medium.com/@penkov.vladimir/mirrormaker2-and-topics-configuration-ee56cb77affd

All possible properties can be found here: 
https://cwiki.apache.org/confluence/display/KAFKA/KIP-382%3A+MirrorMaker+2.0#KIP382:MirrorMaker2.0-ConnectorConfigurationProperties

Now we need to deploy these conf files to kafka connect. I wrote a simple sh script, 
which allows me to deploy/redeploy them by the source cluster name:

`.mm2.sh`
```shell
CONF_FOLDER="mm2"
TARGET_HOST="localhost:8083"

function validate_cluster_files() {
  cluster=$1

  if [ -z "$cluster" ]; then
    echo "Cluster is empty"
    exit 1
  fi

  res=1
  if [ ! -f "${CONF_FOLDER}/mm2-cpc-${cluster}.json" ]
  then
    echo "Checkpoints conf is missing. Create file kafka-connect/mm2-cpc-${cluster}.json"
    res=2
  fi
  if [ ! -f "${CONF_FOLDER}/mm2-hbc-${cluster}.json" ]
  then
    echo "Heartbeat conf is missing. Create file kafka-connect/mm2-hbc-${cluster}.json"
    res=2
  fi
  if [ ! -f "${CONF_FOLDER}/mm2-msc-${cluster}.json" ]
  then
    echo "Source conf is missing. Create file kafka-connect/mm2-msc-${cluster}.json"
    res=2
  fi

  if [ $res == 2 ]
  then
    exit 1
  fi
}


function deploy_cluster() {
  cluster=$1


  CPC=$(curl -s http://${TARGET_HOST}/connectors/mm2-cpc-${cluster}/status | jq ".connector.state")
  if [ "$CPC" == '"RUNNING"' ]
  then
    echo "Checkpoints connector already deployed"
  else
    echo "Deploying checkpoints connector"
    curl -X PUT -H "Content-Type: application/json" \
      --data @${CONF_FOLDER}/mm2-cpc-${cluster}.json \
      -s -f http://${TARGET_HOST}/connectors/mm2-cpc-${cluster}/config >> /dev/null || \
      echo "ERROR: Failed to deploy checkpoints connector"
  fi


  HBC=$(curl -s http://${TARGET_HOST}/connectors/mm2-hbc-${cluster}/status | jq ".connector.state")
  if [ "$HBC" == '"RUNNING"' ]
  then
    echo "Heartbeat connector already deployed"
  else
    echo "Deploying heartbeats connector"
    curl -X PUT -s -f -H "Content-Type: application/json" \
      --data @${CONF_FOLDER}/mm2-hbc-${cluster}.json \
      http://${TARGET_HOST}/connectors/mm2-hbc-${cluster}/config >> /dev/null || \
      echo "ERROR: Failed to deploy heartbeats connector"
  fi


  MSC=$(curl -s http://${TARGET_HOST}/connectors/mm2-msc-${cluster}/status | jq ".connector.state")
  if [ "$MSC" == '"RUNNING"' ]
  then
    echo "Source connector already deployed"
  else
    echo "Deploying source connector"
    curl -X PUT -s -f -H "Content-Type: application/json" \
      --data @${CONF_FOLDER}/mm2-msc-${cluster}.json \
      http://${TARGET_HOST}/connectors/mm2-msc-${cluster}/config >> /dev/null || \
      echo "ERROR: Failed to deploy source connector"
  fi
}

function undeploy_cluster() {
  cluster=$1
  curl -X DELETE -s -f http://${TARGET_HOST}/connectors/mm2-cpc-${cluster} || echo "WARN: checkpoints connector not found"
  echo "Checkpoints connector undeployed"
  curl -X DELETE -s -f http://${TARGET_HOST}/connectors/mm2-hbc-${cluster} || echo "WARN: heartbeats connector not found"
  echo "Heartbeats connector undeployed"
  curl -X DELETE -s -f http://${TARGET_HOST}/connectors/mm2-msc-${cluster} || echo "WARN: source connector not found"
  echo "Source connector undeployed"

}



action=$1
cluster=$2
case $action in

deploy)
  validate_cluster_files "$cluster"
  echo "Deploying cluster $cluster"
  deploy_cluster "$cluster"
  ;;

undeploy)
  echo "Undeploying cluster $cluster"
  undeploy_cluster "$cluster"
  ;;

redeploy)
  validate_cluster_files "$cluster"
  echo "Redeploying cluster $cluster"
  undeploy_cluster "$cluster"
  deploy_cluster "$cluster"
  ;;

status)
  # validate_cluster_files "$cluster"
  CPC=$(curl -s http://${TARGET_HOST}/connectors/mm2-cpc-${cluster}/status | jq ".connector.state")
  HBC=$(curl -s http://${TARGET_HOST}/connectors/mm2-hbc-${cluster}/status | jq ".connector.state")
  MSC=$(curl -s http://${TARGET_HOST}/connectors/mm2-msc-${cluster}/status | jq ".connector.state")
  echo "Checkpoint connector: $CPC"
  echo "Heartbeat connector: $HBC"
  echo "Source connector: $MSC"
  ;;

*)
  echo "usage: mm2.sh [deploy | undeploy | redeploy | status] cluster"
  ;;
esac
```



Run:
```shell
./mm2.sh deploy source-0
```
Open kafka-ui and check, that
1.	Kafka connect contains connectors
2.	Topic was replicated in target-0 cluster

# Conslusion
We can see that the replication is working. All messages appeared in target cluster.

# Links
1. KIP-382: MirrorMaker 2.0 https://cwiki.apache.org/confluence/display/KAFKA/KIP-382%3A+MirrorMaker+2.0
2. Apache Kafka MirrorMaker 2 (MM2) Part 1: Theory  https://www.instaclustr.com/blog/kafka-mirrormaker-2-theory/
3. MirrorMaker 2 on Kafka Connect  
   https://catalog.workshops.aws/msk-labs/en-US/migration/mirrormaker2/usingkafkaconnectgreaterorequal270/customreplautosync/setupmm2





