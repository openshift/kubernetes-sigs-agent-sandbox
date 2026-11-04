#!/usr/bin/env bash
# Run the TLS scanner against the agent-sandbox operator namespace.
#
# Prerequisites:
#   - Logged into an OCP cluster (oc whoami)
#   - The agent-sandbox operator is deployed
#   - ../../../tls-scanner repo exists (or override TLS_SCANNER_DIR)
#   - Scanner image is pushed (or override SCANNER_IMAGE)
#
# Usage:
#   ./dev/ci/tls-scan.sh              # run all 3 tasks
#   ./dev/ci/tls-scan.sh baseline     # task 1 only
#   ./dev/ci/tls-scan.sh pqc          # task 2 only
#   ./dev/ci/tls-scan.sh modern       # task 3 only (switches TLS profile!)
#
# Environment Variables:
#   SCANNER_IMAGE     - Scanner image (default: quay.io/eesposit/tls-scanner:latest)
#   NAMESPACE         - Namespace to scan (default: agent-sandbox-system)
#   TLS_SCANNER_DIR   - Path to tls-scanner repo (default: ../tls-scanner relative to repo root)
#   RESULTS_DIR       - Where to store results (default: ./tls-scan-results)
#
# Each task saves the scanner artifacts (results.csv, results.json, scan.log)
# plus scanner.log, the scanner pod's stdout. --pqc-check does not change the
# CSV/JSON, so scanner.log is where the PASSED/FAILED verdict lives. The script
# exits non-zero when a PQC check reports FAILED.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCANNER_IMAGE="${SCANNER_IMAGE:-quay.io/eesposit/tls-scanner:latest}"
NAMESPACE="${NAMESPACE:-agent-sandbox-system}"
TLS_SCANNER_DIR="${TLS_SCANNER_DIR:-$(cd "$REPO_ROOT/.." && pwd)/tls-scanner}"
RESULTS_DIR="${RESULTS_DIR:-${REPO_ROOT}/tls-scan-results}"
_ORIGINAL_TLS_PROFILE=""
SCANNER_COMMON_ENV="SCANNER_IMAGE=${SCANNER_IMAGE} NAMESPACE=${NAMESPACE} NAMESPACE_FILTER=${NAMESPACE} ARTIFACT_WAIT=30 SCANNER_CPU_REQUEST=500m SCANNER_CPU_LIMIT=500m SCANNER_MEM_REQUEST=1Gi SCANNER_MEM_LIMIT=1Gi"

if [ ! -d "$TLS_SCANNER_DIR" ]; then
    echo "Error: tls-scanner repo not found at $TLS_SCANNER_DIR"
    echo "Clone it or set TLS_SCANNER_DIR."
    exit 1
fi

# Verify cluster access
if ! oc whoami &>/dev/null; then
    echo "Error: not logged into an OCP cluster."
    exit 1
fi

# Verify operator is deployed
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    echo "Error: namespace $NAMESPACE does not exist. Deploy the operator first."
    exit 1
fi

# Capture the scanner pod's stdout before cleanup deletes the Job. This is the
# only place the PQC verdict ("PQC COMPLIANCE CHECK: PASSED|FAILED") and the
# scanner's exit code survive: --pqc-check emits its verdict on stdout, writes
# a JUnit file only when --junit-file is passed, and leaves results.csv/json
# untouched, while deploy.sh copies just the three artifact files.
collect_scanner_logs() {
    local label="$1"
    local pod
    pod=$(oc get pods -n "$NAMESPACE" -l job-name=tls-scanner-job \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$pod" ]; then
        echo "Warning: no scanner pod found; skipping log capture for $label." >&2
        return 0
    fi
    if oc logs "pod/$pod" -n "$NAMESPACE" > "$RESULTS_DIR/$label/scanner.log" 2>/dev/null; then
        echo "==> Scanner pod logs saved to $RESULTS_DIR/$label/scanner.log"
    else
        echo "Warning: could not capture scanner pod logs for $label." >&2
    fi
}

deploy_and_collect() {
    local label="$1"
    local extra_env="${2:-}"
    local job_template="${3:-scanner-job.yaml.template}"

    echo ""
    echo "========================================================================"
    echo "==> $label"
    echo "========================================================================"

    cd "$TLS_SCANNER_DIR"

    env $SCANNER_COMMON_ENV $extra_env \
        JOB_TEMPLATE_FILE="$job_template" \
        ./deploy.sh deploy

    mkdir -p "$RESULTS_DIR/$label"
    cp artifacts/* "$RESULTS_DIR/$label/"

    # Must run before cleanup deletes the Job (and its pod).
    collect_scanner_logs "$label"

    env SCANNER_IMAGE="$SCANNER_IMAGE" NAMESPACE="$NAMESPACE" \
        ./deploy.sh cleanup

    cd "$REPO_ROOT"
    echo "==> $label results saved to $RESULTS_DIR/$label/"
}

wait_for_apiserver_stable() {
    local timeout="${1:-600}"
    local start_time
    start_time=$(date +%s)

    echo "Waiting for API servers to stabilize (timeout: ${timeout}s)..."
    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        if [ "$elapsed" -gt "$timeout" ]; then
            echo "Error: API server did not stabilize within ${timeout}s."
            return 1
        fi

        if ! oc get nodes &>/dev/null; then
            echo "  API server not responding. Elapsed: ${elapsed}s"
            sleep 20
            continue
        fi

        local kube_ready
        kube_ready=$(oc get pods -n openshift-kube-apiserver -l app=openshift-kube-apiserver \
            -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
            | tr ' ' '\n' | { grep -c True || true; })
        local ocp_ready
        ocp_ready=$(oc get pods -n openshift-apiserver -l apiserver=true \
            -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
            | tr ' ' '\n' | { grep -c True || true; })

        echo "  kube-apiserver: ${kube_ready} ready, openshift-apiserver: ${ocp_ready} ready. Elapsed: ${elapsed}s"

        if [ "$kube_ready" -gt 0 ] && [ "$ocp_ready" -gt 0 ] && oc get apiserver cluster &>/dev/null; then
            echo "API server stable."
            return 0
        fi
        sleep 20
    done
}

run_baseline() {
    deploy_and_collect "1-baseline"
}

run_pqc() {
    # Create a PQC job template that adds --pqc-check
    local pqc_template
    pqc_template=$(mktemp)
    sed 's|--csv-file /artifacts/results.csv|--csv-file /artifacts/results.csv --pqc-check|' \
        "$TLS_SCANNER_DIR/scanner-job.yaml.template" > "$pqc_template"
    deploy_and_collect "2-pqc" "" "$pqc_template"
    rm -f "$pqc_template"
}

run_modern() {
    echo ""
    echo "========================================================================"
    echo "==> Task 3: Modern TLS profile scan"
    echo "========================================================================"

    # Check if already Modern — skip the switch and restore if so
    local current_type
    current_type=$(oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile.type}' 2>/dev/null || echo "")
    local already_modern=false
    if [ "$current_type" = "Modern" ]; then
        echo "Cluster TLS profile is already Modern — skipping profile switch."
        already_modern=true
    fi

    if [ "$already_modern" = "false" ]; then
        # Save original profile (script-level so the EXIT trap can access it)
        _ORIGINAL_TLS_PROFILE=$(oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile}' 2>/dev/null || echo "")

        # Restore on exit/error
        restore_profile() {
            echo ""
            echo "==> Restoring original TLS profile..."
            if [ -z "$_ORIGINAL_TLS_PROFILE" ] || [ "$_ORIGINAL_TLS_PROFILE" = "null" ]; then
                oc patch apiserver cluster --type=json \
                    -p='[{"op":"remove","path":"/spec/tlsSecurityProfile"}]' 2>/dev/null \
                    || oc patch apiserver cluster --type=merge \
                        -p '{"spec":{"tlsSecurityProfile":null}}' 2>/dev/null || true
            else
                oc patch apiserver cluster --type=merge \
                    -p "{\"spec\":{\"tlsSecurityProfile\":$_ORIGINAL_TLS_PROFILE}}" 2>/dev/null || true
            fi
            wait_for_apiserver_stable 600 || echo "Warning: API server may not have fully stabilized."
        }
        trap restore_profile EXIT

        # Switch to Modern
        echo "Switching cluster TLS profile to Modern (TLS 1.3 only)..."
        oc patch apiserver cluster --type=merge \
            -p '{"spec":{"tlsSecurityProfile":{"type":"Modern","modern":{}}}}'

        wait_for_apiserver_stable 600

        # Also wait for operator pods to pick up the change
        echo "Waiting 60s for operator pods to reconcile TLS profile..."
        sleep 60
    fi

    # Run scan with PQC check in Modern mode
    local pqc_template
    pqc_template=$(mktemp)
    sed 's|--csv-file /artifacts/results.csv|--csv-file /artifacts/results.csv --pqc-check|' \
        "$TLS_SCANNER_DIR/scanner-job.yaml.template" > "$pqc_template"
    deploy_and_collect "3-modern-profile" "" "$pqc_template"
    rm -f "$pqc_template"

    # restore_profile runs via EXIT trap
}

print_summary() {
    echo ""
    echo "========================================================================"
    echo "==> TLS Scan Summary"
    echo "========================================================================"
    local pqc_failed=false
    for dir in "$RESULTS_DIR"/*/; do
        local name
        name=$(basename "$dir")
        echo ""
        echo "--- $name ---"
        if [ -f "$dir/results.csv" ]; then
            echo "Pod                                                  Port  Status        TLS1.3  ML-KEM  PQC"
            grep -v "^IP" "$dir/results.csv" | awk -F',' '{printf "%-52s %-5s %-13s %-7s %-7s %s\n", $6, $2, $15, $18, $19, $24}'
        else
            echo "  (no results)"
        fi

        if [ -f "$dir/scanner.log" ]; then
            local exit_line verdict
            exit_line=$(grep -m1 "Scanner finished with exit code:" "$dir/scanner.log" | sed 's/^[[:space:]]*//' || true)
            verdict=$(grep -m1 "PQC COMPLIANCE CHECK:" "$dir/scanner.log" | sed 's/^[[:space:]]*//' || true)
            [ -n "$exit_line" ] && echo "  $exit_line"
            if [ -n "$verdict" ]; then
                echo "  $verdict"
                case "$verdict" in
                    *FAILED*) pqc_failed=true ;;
                esac
            fi
        else
            echo "  (no scanner.log — pod stdout was not captured)"
        fi
    done
    echo ""
    echo "Full results in: $RESULTS_DIR/"

    if [ "$pqc_failed" = "true" ]; then
        echo "PQC CHECK FAILED: at least one endpoint lacks TLS 1.3 + ML-KEM."
        return 1
    fi
    return 0
}

# --- Main ---
mkdir -p "$RESULTS_DIR"

ACTION="${1:-all}"
case "$ACTION" in
    baseline)
        run_baseline
        ;;
    pqc)
        run_pqc
        ;;
    modern)
        run_modern
        ;;
    all)
        run_baseline
        run_pqc
        run_modern
        ;;
    *)
        echo "Usage: $0 [baseline|pqc|modern|all]"
        exit 1
        ;;
esac

if ! print_summary; then
    exit 1
fi
