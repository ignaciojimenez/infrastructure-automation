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

# Notifies, gives Docker's own restart policy a moment, then reports whether
# the container came back.
#
# It used to try to self-heal with `source stop_run_ha`, removed 2026-08-28.
# That line had never once executed — `~/.scripts` is on no PATH, cron's or a
# login shell's — and repairing the path would have been worse than the bug:
#
#   * `stop_run_ha` is a CLI taking {start|stop|restart|status}; sourced with no
#     argument it prints usage and restarts nothing;
#   * it opens with `set -euo pipefail`, and `source` would impose that on THIS
#     script's shell;
#   * its CONTAINER_NAME is hardcoded to home-assistant, so a dead `mosquitto`
#     or `cloudflared` would have restarted Home Assistant instead.
#
# Nothing is lost by dropping it. Every container here runs with
# restart_policy: unless-stopped, which covers crashes, non-zero exits and
# reboots on its own — cloudflared has a RestartCount of 28 from exactly that.
# The one case left uncovered is a container a human deliberately stopped, and
# `unless-stopped` declines to restart those by design. See TODO item 20.
notify_and_recheck(){
  echo "$(date) - $(basename "$0") - ERROR: $container not running"
  d_output=$(get_docker_output)
  content="{\"text\":\"\`$(hostname)\` - \`${container}\` is not running\n \`\`\`${d_output}\`\`\` \"}"
  echo "$(date) - $(basename "$0") - Webhook result: $(curl -s -X POST -H 'Content-type: application/json' --data "${content}" "$slack_wh")"
  touch "${notokfile}"
  # Docker's restart policy acts within a second or two; give it that much
  # before deciding, so a self-healed crash is reported as recovery.
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

  # Report the outcome in the exit status.
  #
  # ⚠️ Until 2026-08-28 nothing here did. The script exited non-zero purely by
  # ACCIDENT: `source stop_run_ha` failed on every run, and that failure was the
  # last command's status, which became the script's. Removing the dead line
  # therefore removed the only signal the wrapper ever received — the check
  # would post its own Slack message and still exit 0, so enhanced_monitoring_
  # wrapper would record success and apply no state tracking, no repeat
  # suppression and no ALERT formatting.
  [ "$container_running" == "true" ]
}

# if the container is running at all
if ! docker ps | grep "${container}" > /dev/null ; then
  notify_and_recheck "ps" || exit 1
# if container is in a sane state 
elif [ "$( docker container inspect -f '{{.State.Status}}' "${container}" )" != "running" ]; then
  notify_and_recheck "state" || exit 1
elif test -f "${notokfile}"; then
  echo "$(date) - $(basename "$0") - $container is again running"
  d_output=$(get_docker_output)
  content="{\"text\":\"\`$(hostname)\` - \`${container}\` is again running\n \`\`\`${d_output}\`\`\` \"}"
  echo "$(date) - $(basename "$0") - Webhook result: $(curl -s -X POST -H 'Content-type: application/json' --data "${content}" "$slack_wh")"
  rm "${notokfile}"
else
  echo "$(date) - $(basename "$0") - $container is running"
fi