#!/bin/bash
# =============================================================================
# verify.sh — Verify all cluster nodes are Ready
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

verify_cluster() {
    log_info "Waiting for all nodes to become Ready..."

    local retries=20
    local wait=15

    for attempt in $(seq 1 $retries); do
        local not_ready
        not_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -v "^Ready$" | wc -l)

        if [[ "$not_ready" -eq 0 ]]; then
            log_success "All nodes are Ready"
            echo ""
            kubectl get nodes
            return 0
        fi

        log_warn "Attempt $attempt/$retries — $not_ready node(s) not ready yet, waiting ${wait}s..."
        sleep $wait
    done

    log_error "Timed out waiting for nodes to become Ready"
    kubectl get nodes
    exit 1
}
