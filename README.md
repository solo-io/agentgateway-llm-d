# agentgateway + llm-d Demo

This repo turns the upstream [simulated-accelerators](https://github.com/llm-d/llm-d/blob/v0.5.1/guides/simulated-accelerators/README.md) path into a repeatable demo harness for `llm-d` with `agentgateway`.

It pins:

- `llm-d`: [PR #421](https://github.com/llm-d/llm-d/pull/421) at commit `5a747ab5f794fec1310828acd3a46cd06b9f6f92`
- `llm-d-infra`: [PR #272](https://github.com/llm-d-incubation/llm-d-infra/pull/272) at commit `83a7cb10fd764cf666e1c09980a7e95d94b74329`
- Gateway API CRDs: `v1.5.1`
- GAIE CRDs/chart: `v1.4.0`
- `agentgateway`: `v1.0.0`
- kind node image: `kindest/node:v1.34.0`
- scheduler image: `docker.io/danehans/llm-d-inference-scheduler:v0.7.0-rc.2` (replace with upstream when v0.7.0 is released)
- routing sidecar image: `docker.io/danehans/llm-d-routing-sidecar:v0.7.0-rc.2` (replace with upstream when v0.7.0 is released)

## Prerequisites

- `kind`
- `kubectl`
- `helm`
- `helmfile`
- `docker`
- `git`
- `curl`
- `jq` is optional, but recommended for pretty JSON output

## Quick Start

```bash
cp config/demo.env.example config/demo.env
./scripts/demo.sh setup
./scripts/demo.sh port-forward start
./scripts/demo.sh smoke
```

After the port-forwards are up:

- Inference gateway: `http://127.0.0.1:18000`
- Gateway test endpoint: `http://127.0.0.1:18000/v1/models`
- Prometheus: `http://127.0.0.1:19090`
- Grafana: `http://127.0.0.1:13000`
- Grafana credentials: `admin` / `admin`

The gateway listener in this demo serves the model endpoints, so checking `/` is not a useful readiness signal. Use `/v1/models`, `./scripts/demo.sh smoke`, or `./scripts/demo.sh walkthrough`.

## Manual Checks

With `./scripts/demo.sh port-forward start` running, you can manually verify the gateway with:

```bash
curl -sS --fail-with-body http://127.0.0.1:18000/v1/models | jq .
```

```bash
curl -sS --fail-with-body \
  -H 'Content-Type: application/json' \
  -d '{"model":"random","prompt":"Say hello in one short sentence.","max_tokens":32}' \
  http://127.0.0.1:18000/v1/completions | jq .
```

```bash
curl -sS --fail-with-body \
  -H 'Content-Type: application/json' \
  -d '{"model":"random","messages":[{"role":"user","content":"Say hello in one short sentence."}],"max_tokens":32}' \
  http://127.0.0.1:18000/v1/chat/completions | jq .
```

For a direct baseline comparison against the prefill pod, port-forward the baseline service first:

```bash
kubectl port-forward -n llm-d-sim svc/ms-sim-prefill-direct 18080:8000
```

Then compare request time through the gateway and directly to the prefill service:

```bash
curl -sS -o /dev/null -w 'gateway total=%{time_total}\n' \
  -H 'Content-Type: application/json' \
  -d '{"model":"random","prompt":"Benchmark request","max_tokens":64}' \
  http://127.0.0.1:18000/v1/completions
```

```bash
curl -sS -o /dev/null -w 'baseline total=%{time_total}\n' \
  -H 'Content-Type: application/json' \
  -d '{"model":"random","prompt":"Benchmark request","max_tokens":64}' \
  http://127.0.0.1:18080/v1/completions
```

The file-backed request bodies used by the smoke tests are in `payloads/completions.json` and `payloads/chat-completions.json`.

## Traffic Generation

To drive traffic through the inference gateway from inside the cluster and light up the monitoring graphs:

```bash
./scripts/demo.sh traffic start
./scripts/demo.sh traffic status
```

This now creates:

- a direct baseline `Service` named `ms-sim-prefill-direct` that fronts the prefill pod on port `8000`
- one in-cluster traffic deployment targeting the inference gateway
- one in-cluster traffic deployment targeting the direct baseline service

Both traffic deployments run the same wave profile so the graphs are not flat:

- prompt size varies from short to large contexts
- `max_tokens` varies with the prompt profile
- burst size changes per phase
- pause duration changes per phase

The request mix includes:

- `GET /v1/models`
- `POST /v1/completions`
- `POST /v1/chat/completions`

Stop it with:

```bash
./scripts/demo.sh traffic stop
```

## Common Commands

```bash
./scripts/demo.sh preflight
./scripts/demo.sh sync-sources
./scripts/demo.sh setup
./scripts/demo.sh status
./scripts/demo.sh walkthrough
./scripts/demo.sh port-forward status
./scripts/demo.sh cleanup
```

Use `./scripts/demo.sh --auto walkthrough` to skip interactive pauses.

## Repo Layout

- `scripts/demo.sh`: main entrypoint
- `deploy/`: local Helmfiles with pinned `agentgateway` and GAIE versions
- `values/`: values files for the simulated-accelerators stack
- `templates/httproute.yaml.tmpl`: rendered into the active HTTPRoute during setup
- `payloads/`: sample request bodies used by the smoke tests
- `config/demo.env.example`: override file for local customization

## Notes

- The demo script clones pinned `llm-d` and `llm-d-infra` checkouts into `.cache/` unless you provide `LLMD_LOCAL_PATH` or `LLMD_INFRA_LOCAL_PATH` in `config/demo.env`.
- Monitoring is installed from the pinned upstream `llm-d` checkout so the Grafana dashboards and monitoring scripts stay aligned with that branch.
- `cleanup` deletes the dedicated demo kind cluster and stops background helpers, but keeps the cached source checkouts.
