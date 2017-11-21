#!/usr/bin/env bash

AIRFLOW_HOME="/usr/local/airflow"
CMD="airflow"
TRY_LOOP="20"

: ${REDIS_HOST:="redis"}
: ${REDIS_PORT:="6379"}
: ${REDIS_PASSWORD:=""}

: ${USE_RABBITMQ:="yes"}
: ${RABBITMQ_HOST:="rabbitmq"}
: ${RABBITMQ_PORT:="5672"}
: ${RABBITMQ_USER:="airflow"}
: ${RABBITMQ_PASSWORD:="airflow"}
: ${RABBITMQ_VHOST:="airflow"}

: ${POSTGRES_HOST:="postgres"}
: ${POSTGRES_PORT:="5432"}
: ${POSTGRES_USER:="airflow"}
: ${POSTGRES_PASSWORD:="airflow"}
: ${POSTGRES_DB:="airflow"}

: ${FERNET_KEY:=$(python -c "from cryptography.fernet import Fernet; FERNET_KEY = Fernet.generate_key().decode(); print(FERNET_KEY)")}


if [ "$USE_RABBITMQ" == "yes" ] ; then
    TEST_HOST=$RABBITMQ_HOST
    TEST_PORT=$RABBITMQ_PORT
else
    TEST_HOST=$REDIS_HOST
    TEST_PORT=$REDIS_PORT
fi

# Load DAGs exemples (default: Yes)
if [ "$LOAD_EX" == "n" ]; then
    sed -i "s/load_examples = True/load_examples = False/" "$AIRFLOW_HOME"/airflow.cfg
fi

# Install custome python package if requirements.txt is present
if [ -e "/requirements.txt" ]; then
    $(which pip) install --user -r /requirements.txt
fi

# Update airflow config - Fernet key
sed -i "s|\$FERNET_KEY|$FERNET_KEY|" "$AIRFLOW_HOME"/airflow.cfg

if [ -n "$REDIS_PASSWORD" ]; then
    REDIS_PREFIX=:${REDIS_PASSWORD}@
else
    REDIS_PREFIX=
fi

# Wait for Postresql
if [ "$1" == "webserver" ] || [ "$1" == "worker" ] || [ "$1" == "scheduler" ] ; then
  i=0
  while ! nc -z $POSTGRES_HOST $POSTGRES_PORT >/dev/null 2>&1 < /dev/null; do
    i=$((i+1))
    if [ "$1" == "webserver" ]; then
      echo "$(date) - waiting for ${POSTGRES_HOST}:${POSTGRES_PORT}... $i/$TRY_LOOP"
      if [ $i -ge $TRY_LOOP ]; then
        echo "$(date) - ${POSTGRES_HOST}:${POSTGRES_PORT} still not reachable, giving up"
        exit 1
      fi
    fi
    sleep 10
  done
fi

# Update configuration depending the type of Executor
if [ "$EXECUTOR" == "Celery" ]
then
  # Wait for Redis
  if [ "$1" == "webserver" ] || [ "$1" == "worker" ] || [ "$1" == "scheduler" ] || [ "$1" == "flower" ] ; then
    j=0
    while ! nc -z $TEST_HOST $TEST_PORT >/dev/null 2>&1 < /dev/null; do
      j=$((j+1))
      if [ $j -ge $TRY_LOOP ]; then
        echo "$(date) - $REDIS_HOST still not reachable, giving up"
        exit 1
      fi
      echo "$(date) - waiting for Redis... $j/$TRY_LOOP"
      sleep 5
    done
  fi
  sed -i "s#celery_result_backend = db+postgresql://airflow:airflow@postgres/airflow#celery_result_backend = db+postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB#" "$AIRFLOW_HOME"/airflow.cfg
  sed -i "s#sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@postgres/airflow#sql_alchemy_conn = postgresql+psycopg2://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB#" "$AIRFLOW_HOME"/airflow.cfg
  echo "1"
  if [ "y$USE_RABBITMQ" == "yyes" ] ; then
    echo "USE RABBITMQ"
    sed -i "s#broker_url = redis://redis:6379/1#broker_url = amqp://$RABBITMQ_USER:$RABBITMQ_PASSWORD@$RABBITMQ_HOST:$RABBITMQ_PORT/$RABBITMQ_VHOST#" "$AIRFLOW_HOME"/airflow.cfg
  else
    echo "2"
    sed -i "s#broker_url = redis://redis:6379/1#broker_url = redis://$REDIS_PREFIX$REDIS_HOST:$REDIS_PORT/1#" "$AIRFLOW_HOME"/airflow.cfg
  fi
  echo "3"
  if [ "$1" == "webserver" ]; then
    echo "Initialize database..."
    $CMD initdb
    exec $CMD webserver
  else
    sleep 10
    exec $CMD "$@"
  fi
elif [ "$EXECUTOR" == "Local" ]
then
  echo "LOCAL"
  sed -i "s/executor = CeleryExecutor/executor = LocalExecutor/" "$AIRFLOW_HOME"/airflow.cfg
  sed -i "s#sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@postgres/airflow#sql_alchemy_conn = postgresql+psycopg2://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB#" "$AIRFLOW_HOME"/airflow.cfg
  if [ "y$USE_RABBITMQ" == "yyes" ] ; then
    sed -i "s#broker_url = redis://redis:6379/1#broker_url = amqp://$RABBITMQ_USER:$RABBITMQ_PASSWORD@$RABBITMQ_HOST:$RABBITMQ_PORT/$RABBITMQ_VHOST#" "$AIRFLOW_HOME"/airflow.cfg
  else
    sed -i "s#broker_url = redis://redis:6379/1#broker_url = redis://$REDIS_PREFIX$REDIS_HOST:$REDIS_PORT/1#" "$AIRFLOW_HOME"/airflow.cfg
  fi
  echo "Initialize database..."
  $CMD initdb
  exec $CMD webserver &
  exec $CMD scheduler
# By default we use SequentialExecutor
else
  if [ "$1" == "version" ]; then
    exec $CMD version
    exit
  fi
  sed -i "s/executor = CeleryExecutor/executor = SequentialExecutor/" "$AIRFLOW_HOME"/airflow.cfg
  sed -i "s#sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@postgres/airflow#sql_alchemy_conn = sqlite:////usr/local/airflow/airflow.db#" "$AIRFLOW_HOME"/airflow.cfg
  echo "Initialize database..."
  $CMD initdb
  exec $CMD webserver
fi
