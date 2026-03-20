#!/bin/sh

set -u

: "${TARGET_NAME:=gateway}"
: "${TARGET_URL:?TARGET_URL is required}"
: "${TRAFFIC_INTERVAL_SECONDS:=2}"

log() {
  printf '[%s] %s\n' "${TARGET_NAME}" "$*"
}

build_prompt() {
  words="$1"
  i=0
  prompt=""

  while [ "${i}" -lt "${words}" ]; do
    prompt="${prompt} token${i}"
    i=$((i + 1))
  done

  printf '%s' "${prompt# }"
}

load_profile() {
  phase="$1"

  case $((phase % 6)) in
    0)
      prompt_words=16
      max_tokens=24
      pause_seconds=1
      burst_count=1
      ;;
    1)
      prompt_words=64
      max_tokens=48
      pause_seconds=2
      burst_count=2
      ;;
    2)
      prompt_words=160
      max_tokens=64
      pause_seconds=1
      burst_count=3
      ;;
    3)
      prompt_words=320
      max_tokens=96
      pause_seconds=4
      burst_count=1
      ;;
    4)
      prompt_words=48
      max_tokens=24
      pause_seconds=1
      burst_count=4
      ;;
    5)
      prompt_words=256
      max_tokens=128
      pause_seconds=3
      burst_count=2
      ;;
  esac
}

post_json() {
  url="$1"
  payload="$2"

  if curl -fsS -H 'Content-Type: application/json' -d "${payload}" "${url}" >/dev/null 2>&1; then
    return 0
  fi

  log "request failed: ${url}"
  return 1
}

get_models() {
  if curl -fsS "${TARGET_URL}/v1/models" >/dev/null 2>&1; then
    return 0
  fi

  log "request failed: ${TARGET_URL}/v1/models"
  return 1
}

wait_for_target() {
  retries=60

  while [ "${retries}" -gt 0 ]; do
    if curl -fsS "${TARGET_URL}/v1/models" >/dev/null 2>&1; then
      log "target is ready: ${TARGET_URL}"
      return 0
    fi
    sleep 1
    retries=$((retries - 1))
  done

  log "target did not become ready in time, continuing anyway: ${TARGET_URL}"
  return 0
}

send_request_set() {
  phase="$1"
  burst_index="$2"
  prompt="$(build_prompt "${prompt_words}")"
  completion_payload=$(printf '{"model":"random","prompt":"%s","max_tokens":%s}' "${prompt}" "${max_tokens}")
  chat_payload=$(printf '{"model":"random","messages":[{"role":"user","content":"%s"}],"max_tokens":%s}' "${prompt}" "${max_tokens}")

  if [ $(((phase + burst_index) % 3)) -eq 0 ]; then
    get_models || true
  fi

  post_json "${TARGET_URL}/v1/completions" "${completion_payload}" || true
  post_json "${TARGET_URL}/v1/chat/completions" "${chat_payload}" || true
}

phase=0
extra_pause=0

if [ "${TRAFFIC_INTERVAL_SECONDS}" -gt 1 ]; then
  extra_pause=$((TRAFFIC_INTERVAL_SECONDS - 1))
fi

wait_for_target

while true; do
  load_profile "${phase}"
  burst_index=0

  while [ "${burst_index}" -lt "${burst_count}" ]; do
    send_request_set "${phase}" "${burst_index}"
    burst_index=$((burst_index + 1))
  done

  log "phase=${phase} prompt_words=${prompt_words} max_tokens=${max_tokens} burst_count=${burst_count} pause_seconds=${pause_seconds}"
  phase=$((phase + 1))
  sleep $((pause_seconds + extra_pause))
done
