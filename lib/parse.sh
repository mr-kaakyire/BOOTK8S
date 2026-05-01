#!/bin/bash
# =============================================================================
# parse.sh — install_yq, parse_config, validate_config
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

install_yq() {
    if ! command -v yq &>/dev/null; then
        log_info "Installing yq (YAML parser)..."
        wget -qO /usr/local/bin/yq \
            https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
        chmod +x /usr/local/bin/yq
        log_success "yq installed"
    fi
}

parse_config() {
    local config_file="$1"
    log_info "Parsing config file: $config_file"

    POD_CIDR=$(yq '.cluster.pod_network_cidr' "$config_file")
    K8S_VERSION=$(yq '.cluster.kubernetes_version' "$config_file")
    SSH_KEY=$(yq '.ssh.key_path' "$config_file")
    SSH_USER=$(yq '.ssh.user' "$config_file")

    CP_HOSTNAME=$(yq '.nodes.control_plane.hostname' "$config_file")
    CP_PUBLIC_IP=$(yq '.nodes.control_plane.public_ip' "$config_file")
    CP_PRIVATE_IP=$(yq '.nodes.control_plane.private_ip' "$config_file")

    WORKER_COUNT=$(yq '.nodes.workers | length' "$config_file")
    WORKER_HOSTNAMES=()
    WORKER_PUBLIC_IPS=()
    WORKER_PRIVATE_IPS=()

    for i in $(seq 0 $((WORKER_COUNT - 1))); do
        WORKER_HOSTNAMES+=("$(yq ".nodes.workers[$i].hostname" "$config_file")")
        WORKER_PUBLIC_IPS+=("$(yq ".nodes.workers[$i].public_ip" "$config_file")")
        WORKER_PRIVATE_IPS+=("$(yq ".nodes.workers[$i].private_ip" "$config_file")")
    done

    log_success "Config loaded — 1 control plane, ${WORKER_COUNT} worker(s)"
}

validate_config() {
    log_info "Validating config..."

    local errors=0

    check_field() {
        local name="$1"
        local value="$2"
        if [[ -z "$value" || "$value" == "null" ]]; then
            log_error "Missing config field: $name"
            errors=$((errors + 1))
        fi
    }

    check_field "cluster.pod_network_cidr"       "$POD_CIDR"
    check_field "cluster.kubernetes_version"     "$K8S_VERSION"
    check_field "ssh.key_path"                   "$SSH_KEY"
    check_field "ssh.user"                       "$SSH_USER"
    check_field "nodes.control_plane.hostname"   "$CP_HOSTNAME"
    check_field "nodes.control_plane.public_ip"  "$CP_PUBLIC_IP"
    check_field "nodes.control_plane.private_ip" "$CP_PRIVATE_IP"

    for i in $(seq 0 $((WORKER_COUNT - 1))); do
        check_field "workers[$i].hostname"   "${WORKER_HOSTNAMES[$i]}"
        check_field "workers[$i].public_ip"  "${WORKER_PUBLIC_IPS[$i]}"
        check_field "workers[$i].private_ip" "${WORKER_PRIVATE_IPS[$i]}"
    done

    if [[ ! -f "$SSH_KEY" ]]; then
        log_error "SSH key file not found: $SSH_KEY"
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        log_error "Config validation failed with $errors error(s)"
        exit 1
    fi

    log_success "Config validation passed"
}
