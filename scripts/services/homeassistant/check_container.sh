#!/bin/bash
#
# Script to detect containers not running

set -e          # stop on errors
set -u          # stop on unset variables
set -o pipefail # stop on pipe failures

usage(){
  echo "Usage: $(basename "$0") webhook-id container_name"
}

E_NOARGS=85
wh_regex="T[A-Z0-9]*\/B[A-Z0-9]*\/[a-zA-Z0-9]*"
if [ -z ${1+x} ] || [ -z ${2+x} ] ; then
  usage
  exit "$E_NOARGS"
elif ! [[ $1 =~ $wh_regex ]]; then
  echo "Webhook format invalid. Expected format $wh_regex"
  usage
  exit 1
fi

wh=$1
container=$2

slack_wh="https://hooks.slack.com/services/$wh"

notokfile=${container//\//_}_notok

get_docker_output(){
  #escaping multiline, end of multilie, doubleqoutes
  echo "$(docker ps | sed -z 's/\n/\\n/g; s/..$//; s/\"/\\"/g')"
}

notify_and_reboot(){
  echo "$(date) - $(basename "$0") - ERROR: $container not running"
  d_output=$(get_docker_output)
  content="{\"text\":\"\`$(hostname)\` - \`${container}\` is not running\n \`\`\`${d_output}\`\`\` \"}"
  echo "$(date) - $(basename "$0") - Webhook result: $(curl -s -X POST -H 'Content-type: application/json' --data "${content}" "$slack_wh")"
  touch "${notokfile}"
  source stop_run_ha
  sleep 5

  container_running="false"
  if docker ps | grep "${container}" > /dev/null; then
    if [ "$( docker container inspect -f '{{.State.Status}}' "${container}" )" == "running" ]; then 
      container_running="true"
    fi
  fi

  if [ "$container_running" == "false" ]; then
    if ! test -f "${notokfile}"; then
      echo "$(date) - $(basename "$0") - ERROR: $container still not running"
      d_output=$(get_docker_output)
      content="{\"text\":\"\`$(hostname)\` - \`${container}\` is still not running\n \`\`\`${d_output}\`\`\` \"}"
      echo "$(date) - $(basename "$0") - Webhook result: $(curl -s -X POST -H 'Content-type: application/json' --data "${content}" "$slack_wh")"
      touch "${notokfile}"
    fi
  elif test -f "${notokfile}"; then
    echo "$(date) - $(basename "$0") - $container is again running"
    d_output=$(get_docker_output)
    content="{\"text\":\"\`$(hostname)\` - \`${container}\` is again running\n \`\`\`${d_output}\`\`\` \"}"
    echo "$(date) - $(basename "$0") - Webhook result: $(curl -s -X POST -H 'Content-type: application/json' --data "${content}" "$slack_wh")"
    rm "${notokfile}"
  fi
}

# if the container is running at all
if ! docker ps | grep "${container}" > /dev/null ; then
  notify_and_reboot "ps"
# if container is in a sane state 
elif [ "$( docker container inspect -f '{{.State.Status}}' "${container}" )" != "running" ]; then
  notify_and_reboot "state"
elif test -f "${notokfile}"; then
  echo "$(date) - $(basename "$0") - $container is again running"
  d_output=$(get_docker_output)
  content="{\"text\":\"\`$(hostname)\` - \`${container}\` is again running\n \`\`\`${d_output}\`\`\` \"}"
  echo "$(date) - $(basename "$0") - Webhook result: $(curl -s -X POST -H 'Content-type: application/json' --data "${content}" "$slack_wh")"
  rm "${notokfile}"
else
  echo "$(date) - $(basename "$0") - $container is running"
fi