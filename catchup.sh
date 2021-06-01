#!/bin/bash

set -eu
set -o pipefail

if [ "$#" -ne 5 ]; then
  echo "Usage: ./catchup.sh DOCKER_COMPOSE_FILE LEDGER_MIN LEDGER_MAX CHUNK_SIZE WORKERS"
  exit 1
fi


DOCKER_COMPOSE_FILE=$1
LEDGER_MIN=$2
LEDGER_MAX=$3
CHUNK_SIZE=$4
WORKERS=$5

# temporary files, job queue, and locks
PREFIX=$(mktemp -u -t catchup-XXXX)
JOB_QUEUE=${PREFIX}-job-queue
JOB_QUEUE_LOCK=${PREFIX}-job-queue-lock
touch $JOB_QUEUE_LOCK
mkfifo $JOB_QUEUE

cleanup() {
  rm $JOB_QUEUE
  rm $JOB_QUEUE_LOCK
}
trap cleanup 0

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') $1"
}

run-catchup-job() {
  JOB_ID=$1
  CATCHUP_LEDGER_MIN=$2
  CATCHUP_LEDGER_MAX=$3

  JOB_LOG_FILE=${PREFIX}-job-${JOB_ID}.log

  docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-job-${JOB_ID} up -d digitalbits-core-postgres
  sleep 30
  docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-job-${JOB_ID} run digitalbits-core digitalbits-core new-db --conf /digitalbits-core.cfg 2>&1 > $JOB_LOG_FILE
  docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-job-${JOB_ID} run digitalbits-core digitalbits-core new-hist local --conf /digitalbits-core.cfg 2>&1 >> $JOB_LOG_FILE
  docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-job-${JOB_ID} run digitalbits-core digitalbits-core catchup $CATCHUP_LEDGER_MAX/$(($CATCHUP_LEDGER_MAX - $CATCHUP_LEDGER_MIN)) --conf /digitalbits-core.cfg 2>&1 >> $JOB_LOG_FILE
  docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-job-${JOB_ID} run digitalbits-core digitalbits-core publish --conf /digitalbits-core.cfg 2>&1 >> $JOB_LOG_FILE

  # free up resources (ram, networks), volumes are retained
  docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-job-${JOB_ID} down

  touch ${PREFIX}-job-${JOB_ID}-finished
}

worker() {
  WORKER=$1

  exec 201<$JOB_QUEUE
  exec 202<$JOB_QUEUE_LOCK

  touch ${PREFIX}-worker-$WORKER-started

  log "Worker $WORKER: started."

  while true; do
    flock 202
    read -u 201 JOB_ID JOB_LEDGER_MIN JOB_LEDGER_MAX || { log "Worker $WORKER: finished."; exit 0; }
    flock -u 202

    log "Worker $WORKER: starting job $JOB_ID (ledgers ${JOB_LEDGER_MIN}–${JOB_LEDGER_MAX})."
    run-catchup-job $JOB_ID $JOB_LEDGER_MIN $JOB_LEDGER_MAX
    log "Worker $WORKER: finished job $JOB_ID (ledgers ${JOB_LEDGER_MIN}–${JOB_LEDGER_MAX})."
  done
}

# start workers
for WORKER in $(seq 1 $WORKERS); do
  worker $WORKER &
done

MAX_JOB_ID=$(( ( LEDGER_MAX - LEDGER_MIN ) / CHUNK_SIZE ))
if [ "$(( LEDGER_MIN - 1 + MAX_JOB_ID * CHUNK_SIZE ))" -lt "$LEDGER_MAX" ]; then
  MAX_JOB_ID=$(( MAX_JOB_ID + 1 ))
fi

log "Running $MAX_JOB_ID jobs with $WORKERS workers"

# job producer
{
  exec 201>$JOB_QUEUE

  log "wait for workers"
  # wait for workers to start
  for WORKER in $(seq 1 $WORKERS); do
    while [ ! -f ${PREFIX}-worker-$WORKER-started ]; do
      sleep 1
    done
  done

  # produce jobs
  for JOB_ID in $(seq 1 $MAX_JOB_ID); do
    JOB_LEDGER_MIN=$(( LEDGER_MIN + (JOB_ID - 1) * CHUNK_SIZE))
    JOB_LEDGER_MAX=$(( LEDGER_MIN - 1 + JOB_ID * CHUNK_SIZE ))
    if [ "$JOB_LEDGER_MAX" -ge "$LEDGER_MAX" ]; then
      JOB_LEDGER_MAX=$LEDGER_MAX
    fi
    echo "$JOB_ID $JOB_LEDGER_MIN $JOB_LEDGER_MAX" >& 201
  done
  exec 201<&-
} &

# merge results
log "Starting result database..."
docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-result up -d digitalbits-core-postgres
sleep 60
docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-result run digitalbits-core digitalbits-core new-db --conf /digitalbits-core.cfg

# wipe data to prevent conflicts with job 1
for TABLE in ledgerheaders txhistory txfeehistory upgradehistory; do
  docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-result exec -T digitalbits-core-postgres \
    psql digitalbits-core postgres -c "DELETE FROM $TABLE"
done

for JOB_ID in $(seq 1 $MAX_JOB_ID); do
  log "Waiting for job $JOB_ID..."
  while [ ! -f ${PREFIX}-job-${JOB_ID}-finished ]; do
    sleep 10
  done
  rm -f ${PREFIX}-job-${JOB_ID}-finished
  log "Job $JOB_ID finished, recreating database container..."

  docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-job-${JOB_ID} up -d digitalbits-core-postgres
  sleep 15

  JOB_LEDGER_MIN=$(( LEDGER_MIN + (JOB_ID - 1) * CHUNK_SIZE))
  JOB_LEDGER_MAX=$(( LEDGER_MIN - 1 + JOB_ID * CHUNK_SIZE ))
  if [ "$JOB_LEDGER_MAX" -ge "$LEDGER_MAX" ]; then
    JOB_LEDGER_MAX=$LEDGER_MAX
  fi

  if [ "$JOB_ID" != "1" ]; then
    log "Match last hash of result data with previous hash of the first ledger of job $JOB_ID"
    LAST_RESULT_LEDGER=$(( JOB_LEDGER_MIN - 1))
    LAST_RESULT_HASH=$(docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-result exec digitalbits-core-postgres psql -t digitalbits-core postgres -c "SELECT ledgerhash FROM ledgerheaders WHERE ledgerseq = $LAST_RESULT_LEDGER")
    PREVIOUS_JOB_HASH=$(docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-job-${JOB_ID} exec digitalbits-core-postgres psql -t digitalbits-core postgres -c "SELECT prevhash FROM ledgerheaders WHERE ledgerseq = $JOB_LEDGER_MIN")
    if [ "$LAST_RESULT_HASH" != "$PREVIOUS_JOB_HASH" ]; then
      log "Last result hash $LAST_RESULT_HASH (ledger $LAST_RESULT_LEDGER) does not match previous hash $PREVIOUS_JOB_HASH of first ledger of job $JOB_ID (ledger $JOB_LEDGER_MIN)"
      exit 1
    fi
  fi

  log "Merging database of job $JOB_ID in result database..."
  for TABLE in ledgerheaders txhistory txfeehistory upgradehistory; do
    docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-job-${JOB_ID} exec -T digitalbits-core-postgres \
      psql digitalbits-core postgres -c "COPY (SELECT * FROM $TABLE WHERE ledgerseq >= $JOB_LEDGER_MIN AND ledgerseq <= $JOB_LEDGER_MAX) TO STDOUT WITH (FORMAT BINARY)" |
      docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-result exec -T digitalbits-core-postgres \
      psql digitalbits-core postgres -c "COPY $TABLE FROM STDIN WITH (FORMAT BINARY)"
  done

  if [ "$JOB_ID" = "$MAX_JOB_ID" ]; then
    log "Copy state from job $JOB_ID to result database..."
    for TABLE in accountdata accounts ban offers peers publishqueue pubsub quoruminfo scphistory scpquorums storestate trustlines; do
      # wipe existing data
      docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-result exec -T digitalbits-core-postgres \
        psql digitalbits-core postgres -c "DELETE FROM $TABLE"
      # copy state
      docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-job-${JOB_ID} exec -T digitalbits-core-postgres \
        psql digitalbits-core postgres -c "COPY $TABLE TO STDOUT WITH (FORMAT BINARY)" |
        docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-result exec -T digitalbits-core-postgres \
        psql digitalbits-core postgres -c "COPY $TABLE FROM STDIN WITH (FORMAT BINARY)"
    done
  fi

  log "Merging history of job $JOB_ID..."
  docker container create --name catchup-job-${JOB_ID} -v catchup-job-${JOB_ID}_core-data:/data hello-world
  docker cp catchup-job-${JOB_ID}:/data/history ./history-${JOB_ID}
  if [ "$JOB_ID" = "$MAX_JOB_ID" ]; then
    log "Copy all data from job ${JOB_ID}..."
    docker cp catchup-job-${JOB_ID}:/data ./data-result
  fi
  docker rm catchup-job-${JOB_ID}
  rsync -a ./history-${JOB_ID}/ ./history-result/
  rm -rf ./history-${JOB_ID}

  # clean up job containers and volumes
  docker-compose -f $DOCKER_COMPOSE_FILE -p catchup-job-${JOB_ID} down -v
done

wait

log "Done"
