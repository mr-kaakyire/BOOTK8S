#!/bin/bash
# =============================================================================
# init.sh — Control plane initialisation
# kubeadm init, kubectl config, Flannel, CNI fix, join command extraction
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Initialise the control plane with kubeadm
# Idempotent — skips init if already initialised
init_control_plane() {
    log_info "Initialising control plane..."

    # IDEMPOTENT: skip if already initialised
    if [[ -f /etc/kubernetes/admin.conf ]]; then
        log_warn "Control plane already initialised, skipping kubeadm init"
    else
        run_step "Running kubeadm init" \
            "kubeadm init --pod-network-cidr=${POD_CIDR} > /tmp/kubeadm-init.out 2>&1"

        # Wait for kubelet to be fully active before proceeding
        run_step "Waiting for kubelet to be active" \
            "sleep 15 && systemctl is-active --quiet kubelet"
    fi

    run_step "Configuring kubectl for root" \
        "mkdir -p /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config"

    run_step "Installing Flannel" \
        "kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"

    # IDEMPOTENT: -sf forces overwrite, || true prevents exit on harmless errors
    run_step "Fixing CNI plugin path" \
        "mkdir -p /usr/lib/cni && ln -sf /opt/cni/bin/* /usr/lib/cni/ 2>/dev/null || true && systemctl restart kubelet"

    log_success "Control plane initialised"
}

# Extract or generate the kubeadm join command
# Falls back to generating a fresh token if init output is unavailable
get_join_command() {
    log_info "Extracting join command..."

    JOIN_COMMAND=""

    # Try to extract from kubeadm init output first
    if [[ -f /tmp/kubeadm-init.out ]]; then
        JOIN_COMMAND=$(grep -A2 "kubeadm join" /tmp/kubeadm-init.out \
            | sed 's/\\$//' \
            | tr -d '\n' \
            | sed 's/^[[:space:]]*//' \
            | xargs)
    fi

    # Fall back to generating a fresh token if extraction failed
    if [[ -z "${JOIN_COMMAND:-}" ]]; then
        log_warn "Could not extract from init output, generating fresh join token..."
        JOIN_COMMAND=$(kubeadm token create --print-join-command)
    fi

    if [[ -z "$JOIN_COMMAND" ]]; then
        log_error "Could not generate join command"
        exit 1
    fi

    log_success "Join command ready"
}
