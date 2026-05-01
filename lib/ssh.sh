#!/bin/bash
# =============================================================================
# ssh.sh — check_ssh, run_remote
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Check SSH connectivity to all worker nodes
check_ssh() {
    log_info "Checking SSH connectivity to all nodes..."

    check_node_ssh() {
        local hostname="$1"
        local public_ip="$2"
        if ssh -i "$SSH_KEY" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=10 \
            -o BatchMode=yes \
            "${SSH_USER}@${public_ip}" "echo ok" &>/dev/null; then
            log_success "SSH OK: $hostname ($public_ip)"
        else
            log_error "Cannot SSH into $hostname ($public_ip)"
            log_error "Check your key, security groups, and that the instance is running"
            exit 1
        fi
    }

    for i in $(seq 0 $((WORKER_COUNT - 1))); do
        check_node_ssh "${WORKER_HOSTNAMES[$i]}" "${WORKER_PUBLIC_IPS[$i]}"
    done

    log_success "SSH connectivity verified on all nodes"
}

# Run a script string on a remote node over SSH as root
# Usage: run_remote <public_ip> <script_string>
run_remote() {
    local public_ip="$1"
    local script="$2"

    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        "${SSH_USER}@${public_ip}" \
        "sudo su - root" << SSHEOF >> "$LOG_FILE" 2>&1
$script
SSHEOF
}

# Run a single command on a remote node as root
# Usage: run_remote_cmd <public_ip> <command>
run_remote_cmd() {
    local public_ip="$1"
    local cmd="$2"

    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        "${SSH_USER}@${public_ip}" \
        "sudo su - root -c '${cmd}'" >> "$LOG_FILE" 2>&1
}

# Check if a file exists on a remote node
# Usage: remote_file_exists <public_ip> <filepath>
remote_file_exists() {
    local public_ip="$1"
    local filepath="$2"

    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        "${SSH_USER}@${public_ip}" \
        "test -f ${filepath}" 2>/dev/null
}
