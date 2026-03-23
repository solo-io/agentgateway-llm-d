#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${REPO_ROOT}/config/demo.env"
INTERACTIVE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --auto|--non-interactive|--yes)
      INTERACTIVE=0
      shift
      ;;
    -h|--help)
      set -- help
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ -f "${CONFIG_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
fi

: "${STATE_DIR:=${REPO_ROOT}/.state}"
: "${CACHE_DIR:=${REPO_ROOT}/.cache}"
: "${LOG_DIR:=${STATE_DIR}/logs}"
: "${PID_DIR:=${STATE_DIR}/pids}"
: "${GENERATED_DIR:=${STATE_DIR}/generated}"

: "${KIND_CLUSTER_NAME:=llmd-gaie-140}"
: "${KIND_NODE_IMAGE:=kindest/node:v1.34.0}"
: "${NAMESPACE:=llm-d-sim}"
: "${MONITORING_NAMESPACE:=llm-d-monitoring}"
: "${RELEASE_NAME_POSTFIX:=sim}"

: "${LLMD_REPO_URL:=https://github.com/llm-d/llm-d.git}"
: "${LLMD_REF:=main}"
: "${LLMD_COMMIT:=a57610457d9f5ae193b9683e7a4ead03724cc076}"

: "${LLMD_INFRA_REPO_URL:=https://github.com/llm-d-incubation/llm-d-infra.git}"
: "${LLMD_INFRA_REF:=main}"
: "${LLMD_INFRA_COMMIT:=143620a671cc1f9238da0d25fea44c21876c7e84}"

: "${GATEWAY_API_CRD_REVISION:=v1.5.1}"
: "${GATEWAY_API_INFERENCE_EXTENSION_CRD_REVISION:=v1.4.0}"
: "${GAIE_CHART_VERSION:=v1.4.0}"
: "${AGENTGATEWAY_VERSION:=v1.0.0}"

: "${LLMD_INFERENCE_SCHEDULER_IMAGE_HUB:=docker.io/danehans}"
: "${LLMD_INFERENCE_SCHEDULER_IMAGE_NAME:=llm-d-inference-scheduler}"
: "${LLMD_INFERENCE_SCHEDULER_IMAGE_TAG:=v0.7.0-rc.2}"
: "${LLMD_ROUTING_SIDECAR_IMAGE:=docker.io/danehans/llm-d-routing-sidecar:v0.7.0-rc.2}"

: "${INFERENCE_GATEWAY_LOCAL_PORT:=18000}"
: "${PROMETHEUS_LOCAL_PORT:=19090}"
: "${GRAFANA_LOCAL_PORT:=13000}"

: "${TRAFFIC_GENERATOR_NAME:=demo-traffic-generator}"
: "${TRAFFIC_GENERATOR_IMAGE:=curlimages/curl:8.12.1}"
: "${TRAFFIC_INTERVAL_SECONDS:=2}"
: "${BASELINE_SERVICE_NAME:=ms-sim-prefill-direct}"

COLOR_RESET=$'\033[0m'
COLOR_BLUE=$'\033[34m'
COLOR_GREEN=$'\033[32m'
COLOR_YELLOW=$'\033[33m'
COLOR_RED=$'\033[31m'

log_info() {
  echo "${COLOR_BLUE}==>${COLOR_RESET} $*"
}

log_success() {
  echo "${COLOR_GREEN}==>${COLOR_RESET} $*"
}

log_warn() {
  echo "${COLOR_YELLOW}==>${COLOR_RESET} $*"
}

log_error() {
  echo "${COLOR_RED}==>${COLOR_RESET} $*" >&2
}

die() {
  log_error "$*"
  exit 1
}

ensure_dirs() {
  mkdir -p "${STATE_DIR}" "${CACHE_DIR}" "${LOG_DIR}" "${PID_DIR}" "${GENERATED_DIR}" "${CACHE_DIR}/sources"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

optional_cmd() {
  command -v "$1" >/dev/null 2>&1
}

pause_step() {
  if [[ "${INTERACTIVE}" -eq 1 ]]; then
    echo
    read -r -p "Press Enter to continue..." _
  fi
}

kind_context() {
  printf 'kind-%s' "${KIND_CLUSTER_NAME}"
}

llmd_source_path() {
  if [[ -n "${LLMD_LOCAL_PATH:-}" ]]; then
    printf '%s' "${LLMD_LOCAL_PATH}"
  else
    printf '%s' "${CACHE_DIR}/sources/llm-d"
  fi
}

llmd_infra_source_path() {
  if [[ -n "${LLMD_INFRA_LOCAL_PATH:-}" ]]; then
    printf '%s' "${LLMD_INFRA_LOCAL_PATH}"
  else
    printf '%s' "${CACHE_DIR}/sources/llm-d-infra"
  fi
}

infra_release_name() {
  printf 'infra-%s' "${RELEASE_NAME_POSTFIX}"
}

gaie_release_name() {
  printf 'gaie-%s' "${RELEASE_NAME_POSTFIX}"
}

ms_release_name() {
  printf 'ms-%s' "${RELEASE_NAME_POSTFIX}"
}

inference_gateway_name() {
  printf '%s-inference-gateway' "$(infra_release_name)"
}

httproute_name() {
  printf 'llm-d-%s' "${RELEASE_NAME_POSTFIX}"
}

decode_deployment_name() {
  printf '%s-llm-d-modelservice-decode' "$(ms_release_name)"
}

gaie_deployment_name() {
  printf '%s-epp' "$(gaie_release_name)"
}

prefill_deployment_name() {
  printf '%s-llm-d-modelservice-prefill' "$(ms_release_name)"
}

gateway_service_url() {
  printf 'http://%s.%s.svc.cluster.local' "$(inference_gateway_name)" "${NAMESPACE}"
}

baseline_service_url() {
  printf 'http://%s.%s.svc.cluster.local:8000' "${BASELINE_SERVICE_NAME}" "${NAMESPACE}"
}

gateway_traffic_deployment_name() {
  printf '%s-gateway' "${TRAFFIC_GENERATOR_NAME}"
}

baseline_traffic_deployment_name() {
  printf '%s-baseline' "${TRAFFIC_GENERATOR_NAME}"
}

traffic_script_configmap_name() {
  printf '%s-script' "${TRAFFIC_GENERATOR_NAME}"
}

json_pp() {
  if optional_cmd jq; then
    jq .
  else
    cat
  fi
}

preflight() {
  require_cmd kind
  require_cmd kubectl
  require_cmd helm
  require_cmd helmfile
  require_cmd docker
  require_cmd git
  require_cmd curl
  if ! docker info >/dev/null 2>&1; then
    die "Docker is installed but the daemon is not reachable."
  fi
  if ! optional_cmd jq; then
    log_warn "jq is not installed; JSON responses will be printed without pretty formatting."
  fi
}

sync_repo() {
  local name="$1"
  local url="$2"
  local ref="$3"
  local commit="$4"
  local target="$5"
  local current_url

  if [[ ! -d "${target}/.git" ]]; then
    log_info "Cloning ${name} into ${target}"
    git clone --filter=blob:none --no-checkout "${url}" "${target}"
  else
    current_url="$(git -C "${target}" remote get-url origin 2>/dev/null || true)"
    if [[ -z "${current_url}" ]]; then
      git -C "${target}" remote add origin "${url}"
    elif [[ "${current_url}" != "${url}" ]]; then
      log_info "Updating ${name} remote from ${current_url} to ${url}"
      git -C "${target}" remote set-url origin "${url}"
    fi
  fi

  log_info "Fetching ${name} at ${ref}"
  git -C "${target}" fetch --depth 1 origin "${ref}"
  if ! git -C "${target}" checkout --detach "${commit}" >/dev/null 2>&1; then
    git -C "${target}" fetch --depth 1 origin "${commit}"
    git -C "${target}" checkout --detach "${commit}"
  fi
}

sync_sources() {
  ensure_dirs

  if [[ -n "${LLMD_LOCAL_PATH:-}" ]]; then
    [[ -d "${LLMD_LOCAL_PATH}" ]] || die "LLMD_LOCAL_PATH does not exist: ${LLMD_LOCAL_PATH}"
  else
    sync_repo "llm-d" "${LLMD_REPO_URL}" "${LLMD_REF}" "${LLMD_COMMIT}" "$(llmd_source_path)"
    LLMD_LOCAL_PATH="$(llmd_source_path)"
  fi

  if [[ -n "${LLMD_INFRA_LOCAL_PATH:-}" ]]; then
    [[ -d "${LLMD_INFRA_LOCAL_PATH}" ]] || die "LLMD_INFRA_LOCAL_PATH does not exist: ${LLMD_INFRA_LOCAL_PATH}"
  else
    sync_repo "llm-d-infra" "${LLMD_INFRA_REPO_URL}" "${LLMD_INFRA_REF}" "${LLMD_INFRA_COMMIT}" "$(llmd_infra_source_path)"
    LLMD_INFRA_LOCAL_PATH="$(llmd_infra_source_path)"
  fi

  export LLMD_LOCAL_PATH
  export LLMD_INFRA_LOCAL_PATH
}

use_demo_context() {
  kubectl config use-context "$(kind_context)" >/dev/null
}

create_kind_cluster() {
  if kind get clusters | grep -Fxq "${KIND_CLUSTER_NAME}"; then
    log_info "Reusing existing kind cluster ${KIND_CLUSTER_NAME}"
  else
    log_info "Creating kind cluster ${KIND_CLUSTER_NAME}"
    kind create cluster --name "${KIND_CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}"
  fi

  use_demo_context
  kubectl wait --for=condition=Ready "node/${KIND_CLUSTER_NAME}-control-plane" --timeout=180s
  log_success "kind cluster is ready"
}

install_gateway_provider_dependencies() {
  log_info "Installing Gateway API CRDs ${GATEWAY_API_CRD_REVISION}"
  kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api/config/crd/?ref=${GATEWAY_API_CRD_REVISION}"
  log_info "Installing Gateway API Inference Extension CRDs ${GATEWAY_API_INFERENCE_EXTENSION_CRD_REVISION}"
  kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd/?ref=${GATEWAY_API_INFERENCE_EXTENSION_CRD_REVISION}"
}

install_agentgateway() {
  log_info "Installing agentgateway ${AGENTGATEWAY_VERSION}"
  export AGENTGATEWAY_VERSION
  helmfile -f "${REPO_ROOT}/deploy/agentgateway.helmfile.yaml.gotmpl" apply
  kubectl wait --for=condition=Available deployment/agentgateway -n agentgateway-system --timeout=180s
  log_success "agentgateway is ready"
}

install_monitoring() {
  local monitoring_script

  monitoring_script="$(llmd_source_path)/docs/monitoring/scripts/install-prometheus-grafana.sh"
  [[ -f "${monitoring_script}" ]] || die "Monitoring installer not found: ${monitoring_script}"

  log_info "Installing Prometheus and Grafana into ${MONITORING_NAMESPACE}"
  bash "${monitoring_script}" -n "${MONITORING_NAMESPACE}"
  log_success "Monitoring stack is ready"
}

create_namespace() {
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
}

deploy_stack() {
  export LLMD_INFRA_CHART
  LLMD_INFRA_CHART="$(llmd_infra_source_path)/charts/llm-d-infra"
  [[ -d "${LLMD_INFRA_CHART}" ]] || die "llm-d-infra chart not found: ${LLMD_INFRA_CHART}"

  export LLMD_INFERENCE_SCHEDULER_IMAGE_HUB
  export LLMD_INFERENCE_SCHEDULER_IMAGE_NAME
  export LLMD_INFERENCE_SCHEDULER_IMAGE_TAG
  export LLMD_ROUTING_SIDECAR_IMAGE
  export GAIE_CHART_VERSION
  export RELEASE_NAME_POSTFIX
  export NAMESPACE

  log_info "Deploying the simulated-accelerators stack into ${NAMESPACE}"
  helmfile -f "${REPO_ROOT}/deploy/simulated-accelerators.helmfile.yaml.gotmpl" -n "${NAMESPACE}" apply
}

render_httproute() {
  local rendered="${GENERATED_DIR}/httproute.yaml"
  sed \
    -e "s/__HTTPROUTE_NAME__/$(httproute_name)/g" \
    -e "s/__INFERENCE_GATEWAY_NAME__/$(inference_gateway_name)/g" \
    -e "s/__INFERENCEPOOL_NAME__/$(gaie_release_name)/g" \
    "${REPO_ROOT}/templates/httproute.yaml.tmpl" > "${rendered}"
  printf '%s' "${rendered}"
}

apply_httproute() {
  local rendered

  rendered="$(render_httproute)"
  kubectl apply -f "${rendered}" -n "${NAMESPACE}"
}

wait_for_demo_readiness() {
  kubectl wait pod --for=condition=Ready --all -n "${NAMESPACE}" --timeout=300s
  kubectl wait "gateway/$(inference_gateway_name)" --for=condition=Programmed=True -n "${NAMESPACE}" --timeout=300s
  wait_for_httproute_condition "$(httproute_name)" "Accepted" 300
  wait_for_httproute_condition "$(httproute_name)" "ResolvedRefs" 300
}

verify_expected_images() {
  local scheduler_image
  local sidecar_image
  local expected_scheduler

  expected_scheduler="${LLMD_INFERENCE_SCHEDULER_IMAGE_HUB}/${LLMD_INFERENCE_SCHEDULER_IMAGE_NAME}:${LLMD_INFERENCE_SCHEDULER_IMAGE_TAG}"
  scheduler_image="$(kubectl get deploy "$(gaie_deployment_name)" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  sidecar_image="$(kubectl get deploy "$(decode_deployment_name)" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.initContainers[0].image}')"

  log_info "Scheduler image: ${scheduler_image}"
  log_info "Routing sidecar image: ${sidecar_image}"

  [[ "${scheduler_image}" == "${expected_scheduler}" ]] || die "Unexpected scheduler image: ${scheduler_image}"
  [[ "${sidecar_image}" == "${LLMD_ROUTING_SIDECAR_IMAGE}" ]] || die "Unexpected routing sidecar image: ${sidecar_image}"
}

verify_gateway_service_type() {
  local service_type

  service_type="$(kubectl get agentgatewayparameters.agentgateway.dev "$(inference_gateway_name)" -n "${NAMESPACE}" -o jsonpath='{.spec.service.spec.type}')"
  log_info "Gateway service type: ${service_type}"
  [[ "${service_type}" == "LoadBalancer" ]] || die "Unexpected gateway service type: ${service_type}"
}

status_summary() {
  log_info "Namespace: ${NAMESPACE}"
  kubectl get pods -n "${NAMESPACE}"
  kubectl get gateway,httproute -n "${NAMESPACE}"
  kubectl get svc -n "${NAMESPACE}"
}

pid_file_for() {
  printf '%s/%s.pid' "${PID_DIR}" "$1"
}

log_file_for() {
  printf '%s/%s.log' "${LOG_DIR}" "$1"
}

port_forward_running() {
  local pidfile="$1"
  [[ -f "${pidfile}" ]] || return 1
  kill -0 "$(cat "${pidfile}")" >/dev/null 2>&1
}

wait_for_local_port() {
  local port="$1"
  local retries=30

  while [[ "${retries}" -gt 0 ]]; do
    if optional_cmd nc; then
      if nc -z 127.0.0.1 "${port}" >/dev/null 2>&1; then
        return 0
      fi
    elif optional_cmd lsof; then
      if lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
        return 0
      fi
    else
      sleep 3
      return 0
    fi
    sleep 1
    retries=$((retries - 1))
  done

  return 1
}

wait_for_httproute_condition() {
  local route_name="$1"
  local condition_name="$2"
  local timeout_seconds="${3:-300}"
  local remaining="${timeout_seconds}"
  local status

  while [[ "${remaining}" -gt 0 ]]; do
    status="$(kubectl get "httproute/${route_name}" -n "${NAMESPACE}" -o jsonpath="{range .status.parents[*].conditions[?(@.type==\"${condition_name}\")]}{.status}{end}" 2>/dev/null || true)"
    if [[ "${status}" == *True* ]]; then
      log_success "HTTPRoute ${route_name} condition ${condition_name}=True"
      return 0
    fi
    sleep 2
    remaining=$((remaining - 2))
  done

  kubectl get "httproute/${route_name}" -n "${NAMESPACE}" -o yaml >&2 || true
  die "Timed out waiting for HTTPRoute ${route_name} condition ${condition_name}=True"
}

wait_for_http_ok() {
  local url="$1"
  local retries="${2:-30}"

  while [[ "${retries}" -gt 0 ]]; do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    retries=$((retries - 1))
  done

  return 1
}

start_one_port_forward() {
  local label="$1"
  local namespace="$2"
  local target="$3"
  local ports="$4"
  local pidfile
  local logfile

  pidfile="$(pid_file_for "${label}")"
  logfile="$(log_file_for "${label}")"

  if port_forward_running "${pidfile}"; then
    log_info "Port-forward ${label} is already running"
    return 0
  fi

  if [[ -f "${pidfile}" ]]; then
    rm -f "${pidfile}"
  fi

  log_info "Starting port-forward ${label} (${ports})"
  kubectl -n "${namespace}" port-forward "${target}" "${ports}" > "${logfile}" 2>&1 &
  echo $! > "${pidfile}"

  if ! wait_for_local_port "${ports%%:*}"; then
    log_error "Port-forward ${label} did not become ready. See ${logfile}"
    return 1
  fi
}

stop_one_port_forward() {
  local label="$1"
  local pidfile

  pidfile="$(pid_file_for "${label}")"
  if port_forward_running "${pidfile}"; then
    kill "$(cat "${pidfile}")" >/dev/null 2>&1 || true
    wait "$(cat "${pidfile}")" 2>/dev/null || true
  fi
  rm -f "${pidfile}"
}

port_forward_start() {
  start_one_port_forward "gateway" "${NAMESPACE}" "service/$(inference_gateway_name)" "${INFERENCE_GATEWAY_LOCAL_PORT}:80"
  start_one_port_forward "prometheus" "${MONITORING_NAMESPACE}" "service/llmd-kube-prometheus-stack-prometheus" "${PROMETHEUS_LOCAL_PORT}:9090"
  start_one_port_forward "grafana" "${MONITORING_NAMESPACE}" "service/llmd-grafana" "${GRAFANA_LOCAL_PORT}:80"

  if wait_for_http_ok "http://127.0.0.1:${INFERENCE_GATEWAY_LOCAL_PORT}/v1/models" 30; then
    log_success "Inference gateway is responding on /v1/models"
  else
    log_warn "Inference gateway port-forward is up, but /v1/models did not return 200 yet"
  fi

  log_success "Port-forwards are ready"
  print_access_urls
}

port_forward_stop() {
  stop_one_port_forward "gateway"
  stop_one_port_forward "prometheus"
  stop_one_port_forward "grafana"
  log_success "Port-forwards stopped"
}

port_forward_status() {
  local label
  for label in gateway prometheus grafana; do
    if port_forward_running "$(pid_file_for "${label}")"; then
      echo "${label}: running"
    else
      echo "${label}: stopped"
    fi
  done
  print_access_urls
}

print_access_urls() {
  cat <<EOF
Inference gateway: http://127.0.0.1:${INFERENCE_GATEWAY_LOCAL_PORT}
Gateway test:      curl http://127.0.0.1:${INFERENCE_GATEWAY_LOCAL_PORT}/v1/models
Prometheus:        http://127.0.0.1:${PROMETHEUS_LOCAL_PORT}
Grafana:           http://127.0.0.1:${GRAFANA_LOCAL_PORT} (admin/admin)
EOF
}

print_manual_curl_examples() {
  cat <<EOF

Manual curl checks:
  curl -sS --fail-with-body \\
    -H 'Content-Type: application/json' \\
    -d '{"model":"random","prompt":"Say hello in one short sentence.","max_tokens":32}' \\
    http://127.0.0.1:${INFERENCE_GATEWAY_LOCAL_PORT}/v1/completions | jq .

  curl -sS --fail-with-body \\
    -H 'Content-Type: application/json' \\
    -d '{"model":"random","messages":[{"role":"user","content":"Say hello in one short sentence."}],"max_tokens":32}' \\
    http://127.0.0.1:${INFERENCE_GATEWAY_LOCAL_PORT}/v1/chat/completions | jq .
EOF
}

run_models_request() {
  log_info "GET /v1/models"
  curl -sS --fail-with-body "http://127.0.0.1:${INFERENCE_GATEWAY_LOCAL_PORT}/v1/models" | json_pp
}

run_completions_request() {
  log_info "POST /v1/completions"
  curl -sS --fail-with-body \
    -H 'Content-Type: application/json' \
    --data @"${REPO_ROOT}/payloads/completions.json" \
    "http://127.0.0.1:${INFERENCE_GATEWAY_LOCAL_PORT}/v1/completions" | json_pp
}

run_chat_completions_request() {
  log_info "POST /v1/chat/completions"
  curl -sS --fail-with-body \
    -H 'Content-Type: application/json' \
    --data @"${REPO_ROOT}/payloads/chat-completions.json" \
    "http://127.0.0.1:${INFERENCE_GATEWAY_LOCAL_PORT}/v1/chat/completions" | json_pp
}

e2e_checks() {
  port_forward_start
  run_models_request
  run_completions_request
  run_chat_completions_request
  print_manual_curl_examples
}

apply_traffic_script_configmap() {
  kubectl create configmap "$(traffic_script_configmap_name)" \
    -n "${NAMESPACE}" \
    --from-file=run-traffic.sh="${REPO_ROOT}/scripts/traffic-wave.sh" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
}

apply_baseline_service() {
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${BASELINE_SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${BASELINE_SERVICE_NAME}
    app.kubernetes.io/component: baseline
    app.kubernetes.io/part-of: ${TRAFFIC_GENERATOR_NAME}
spec:
  type: ClusterIP
  selector:
    llm-d.ai/accelerator-variant: cpu
    llm-d.ai/guide: simulated-accelerators
    llm-d.ai/inference-serving: "true"
    llm-d.ai/model: random
    llm-d.ai/role: prefill
  ports:
    - name: http
      port: 8000
      protocol: TCP
      targetPort: 8000
EOF
}

apply_traffic_deployments() {
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $(gateway_traffic_deployment_name)
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: $(gateway_traffic_deployment_name)
    app.kubernetes.io/component: traffic-generator
    app.kubernetes.io/part-of: ${TRAFFIC_GENERATOR_NAME}
    demo.solo.io/traffic-target: gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: $(gateway_traffic_deployment_name)
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $(gateway_traffic_deployment_name)
        app.kubernetes.io/component: traffic-generator
        app.kubernetes.io/part-of: ${TRAFFIC_GENERATOR_NAME}
        demo.solo.io/traffic-target: gateway
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: curl
          image: ${TRAFFIC_GENERATOR_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - /opt/traffic/run-traffic.sh
          env:
            - name: TARGET_NAME
              value: gateway
            - name: TARGET_URL
              value: $(gateway_service_url)
            - name: TRAFFIC_INTERVAL_SECONDS
              value: "${TRAFFIC_INTERVAL_SECONDS}"
          volumeMounts:
            - name: traffic-script
              mountPath: /opt/traffic
      volumes:
        - name: traffic-script
          configMap:
            name: $(traffic_script_configmap_name)
            defaultMode: 0755
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $(baseline_traffic_deployment_name)
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: $(baseline_traffic_deployment_name)
    app.kubernetes.io/component: traffic-generator
    app.kubernetes.io/part-of: ${TRAFFIC_GENERATOR_NAME}
    demo.solo.io/traffic-target: baseline
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: $(baseline_traffic_deployment_name)
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $(baseline_traffic_deployment_name)
        app.kubernetes.io/component: traffic-generator
        app.kubernetes.io/part-of: ${TRAFFIC_GENERATOR_NAME}
        demo.solo.io/traffic-target: baseline
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: curl
          image: ${TRAFFIC_GENERATOR_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - /opt/traffic/run-traffic.sh
          env:
            - name: TARGET_NAME
              value: baseline
            - name: TARGET_URL
              value: $(baseline_service_url)
            - name: TRAFFIC_INTERVAL_SECONDS
              value: "${TRAFFIC_INTERVAL_SECONDS}"
          volumeMounts:
            - name: traffic-script
              mountPath: /opt/traffic
      volumes:
        - name: traffic-script
          configMap:
            name: $(traffic_script_configmap_name)
            defaultMode: 0755
EOF
}

traffic_start() {
  log_info "Creating baseline prefill service ${BASELINE_SERVICE_NAME}"
  apply_baseline_service
  kubectl wait --for=jsonpath='{.subsets[0].addresses[0].ip}' endpoints/"${BASELINE_SERVICE_NAME}" -n "${NAMESPACE}" --timeout=180s

  log_info "Publishing wave traffic script configmap"
  apply_traffic_script_configmap

  log_info "Starting traffic generator deployments $(gateway_traffic_deployment_name) and $(baseline_traffic_deployment_name)"
  apply_traffic_deployments

  kubectl rollout status "deployment/$(gateway_traffic_deployment_name)" -n "${NAMESPACE}" --timeout=180s
  kubectl rollout status "deployment/$(baseline_traffic_deployment_name)" -n "${NAMESPACE}" --timeout=180s
  log_success "Traffic generators are running"
  log_info "Gateway target:  $(gateway_service_url)"
  log_info "Baseline target: $(baseline_service_url)"
}

traffic_stop() {
  kubectl delete deployment "${TRAFFIC_GENERATOR_NAME}" -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete deployment "$(gateway_traffic_deployment_name)" -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete deployment "$(baseline_traffic_deployment_name)" -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete configmap "$(traffic_script_configmap_name)" -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete service "${BASELINE_SERVICE_NAME}" -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  log_success "Traffic generators and baseline service stopped"
}

traffic_status() {
  kubectl get service "${BASELINE_SERVICE_NAME}" -n "${NAMESPACE}" --ignore-not-found
  kubectl get deployment,pod -l "app.kubernetes.io/part-of=${TRAFFIC_GENERATOR_NAME}" -n "${NAMESPACE}" --ignore-not-found
  kubectl logs deployment/"$(gateway_traffic_deployment_name)" -n "${NAMESPACE}" --tail=10 2>/dev/null || true
  kubectl logs deployment/"$(baseline_traffic_deployment_name)" -n "${NAMESPACE}" --tail=10 2>/dev/null || true
}

walkthrough() {
  status_summary
  pause_step
  port_forward_start
  pause_step
  run_models_request
  pause_step
  run_completions_request
  pause_step
  run_chat_completions_request
  pause_step
  log_info "Use the URLs above to inspect Prometheus and Grafana while traffic is flowing."
  print_manual_curl_examples
}

setup() {
  preflight
  sync_sources
  create_kind_cluster
  install_gateway_provider_dependencies
  install_agentgateway
  install_monitoring
  create_namespace
  deploy_stack
  apply_httproute
  wait_for_demo_readiness
  verify_expected_images
  verify_gateway_service_type
  status_summary
  log_success "Setup complete"
}

cleanup() {
  port_forward_stop
  if kind get clusters | grep -Fxq "${KIND_CLUSTER_NAME}"; then
    log_info "Deleting kind cluster ${KIND_CLUSTER_NAME}"
    kind delete cluster --name "${KIND_CLUSTER_NAME}"
  else
    log_warn "kind cluster ${KIND_CLUSTER_NAME} does not exist"
  fi
}

usage() {
  cat <<EOF
Usage:
  ./scripts/demo.sh [--env-file path] [--auto] <command>

Commands:
  preflight            Check local dependencies.
  sync-sources         Clone or update pinned llm-d and llm-d-infra checkouts.
  setup                Build the full demo environment in kind.
  status               Show pods, gateways, routes, and services.
  port-forward start   Forward the inference gateway, Prometheus, and Grafana.
  port-forward stop    Stop background port-forwards.
  port-forward status  Show port-forward state and local URLs.
  e2e                  Run local e2e checks through the port-forwarded gateway.
  walkthrough          Guided local demo flow with pauses between requests.
  traffic start        Launch an in-cluster curl client to generate monitoring traffic.
  traffic stop         Stop the in-cluster traffic generator.
  traffic status       Show traffic generator status and recent logs.
  cleanup              Stop helpers and delete the dedicated kind cluster.
  all                  Run setup, start port-forwards, and execute e2e checks.

Examples:
  ./scripts/demo.sh setup
  ./scripts/demo.sh port-forward start
  ./scripts/demo.sh e2e
  ./scripts/demo.sh traffic start
EOF
}

COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

ensure_dirs

case "${COMMAND}" in
  help)
    usage
    ;;
  preflight)
    preflight
    ;;
  sync-sources)
    preflight
    sync_sources
    ;;
  setup)
    setup
    ;;
  status)
    use_demo_context
    status_summary
    ;;
  port-forward)
    case "${1:-start}" in
      start)
        use_demo_context
        port_forward_start
        ;;
      stop)
        port_forward_stop
        ;;
      status)
        port_forward_status
        ;;
      *)
        usage
        exit 1
        ;;
    esac
    ;;
  e2e)
    use_demo_context
    e2e_checks
    ;;
  smoke)
    use_demo_context
    log_warn "The 'smoke' command is deprecated; use './scripts/demo.sh e2e' instead."
    e2e_checks
    ;;
  walkthrough)
    use_demo_context
    walkthrough
    ;;
  traffic)
    use_demo_context
    case "${1:-start}" in
      start)
        traffic_start
        ;;
      stop)
        traffic_stop
        ;;
      status)
        traffic_status
        ;;
      *)
        usage
        exit 1
        ;;
    esac
    ;;
  cleanup)
    cleanup
    ;;
  all)
    setup
    e2e_checks
    ;;
  *)
    usage
    exit 1
    ;;
esac
