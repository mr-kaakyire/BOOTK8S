#!/bin/bash
# =============================================================================
# join.sh — Join worker nodes to the cluster
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"

# Join each worker to the cluster
# Idempotent — skips workers already joined, resets partial state before joining
join_workers() {
    log_info "Joining workers to the cluster..."

    for i in $(seq 0 $((WORKER_COUNT - 1))); do
        local hostname="${WORKER_HOSTNAMES[$i]}"
        local public_ip="${WORKER_PUBLIC_IPS[$i]}"

        log_info "Checking: $hostname"

        # IDEMPOTENT: kubelet.conf only exists after a successful join
        if remote_file_exists "$public_ip" "/etc/kubernetes/kubelet.conf"; then
            log_warn "$hostname already joined, skipping"
            continue
        fi

        # Reset any partial state from a previous failed join attempt, then join
        log_info "Joining: $hostname"
        if run_remote_cmd "$public_ip" \
            "kubeadm reset -f && rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd && ${JOIN_COMMAND}"; then
            log_success "$hostname joined the cluster"
        else
            log_error "$hostname failed to join — see $LOG_FILE"
            exit 1
        fi
    done
}
