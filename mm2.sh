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
