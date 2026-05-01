#!/bin/bash
# =============================================================================
# setup-cluster.sh — Main entry point
#
# Usage:
#   ./setup-cluster.sh <cluster-config.yaml> [--phase <phase>]
#
# Phases:
#   all         Run everything (default)
#   node-setup  Prepare all nodes (install packages, configure OS)
#   init        Initialise the control plane (kubeadm init, Flannel, CNI)
#   join        Join worker nodes to the cluster
#   verify      Wait for and confirm all nodes are Ready
#
# Examples:
#   ./setup-cluster.sh cluster-config.yaml
#   ./setup-cluster.sh cluster-config.yaml --phase join
#   ./setup-cluster.sh cluster-config.yaml --phase verify
# =============================================================================

set -euo pipefail

# Resolve the directory this script lives in so lib/ sources work
# regardless of where the script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Source all lib files
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/parse.sh"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/lib/node.sh"
source "$SCRIPT_DIR/lib/init.sh"
source "$SCRIPT_DIR/lib/join.sh"
source "$SCRIPT_DIR/lib/verify.sh"

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    log_error "Usage: $0 <cluster-config.yaml> [--phase all|node-setup|init|join|verify]"
    exit 1
fi

CONFIG_FILE="$1"
PHASE="all"

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)
            PHASE="$2"
            shift 2
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Validate phase value
case "$PHASE" in
    all|node-setup|init|join|verify) ;;
    *)
        log_error "Invalid phase: $PHASE. Must be one of: all, node-setup, init, join, verify"
        exit 1
        ;;
esac

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
fi

# -----------------------------------------------------------------------------
# Check script is being run as root
# -----------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

# -----------------------------------------------------------------------------
# Initialise log file
# -----------------------------------------------------------------------------
echo "Kubernetes cluster setup started at $(date) [phase: $PHASE]" >> "$LOG_FILE"

# -----------------------------------------------------------------------------
# Always run these regardless of phase
# -----------------------------------------------------------------------------
echo ""
echo "================================================="
echo "   Kubernetes Cluster Setup  [phase: ${PHASE}]"
echo "================================================="
echo ""

install_yq
parse_config "$CONFIG_FILE"
validate_config

# Only check SSH connectivity if the phase touches worker nodes
if [[ "$PHASE" == "all" || "$PHASE" == "node-setup" || "$PHASE" == "join" ]]; then
    check_ssh
fi

# -----------------------------------------------------------------------------
# Phase: node-setup
# Prepare all nodes — OS config, containerd, Kubernetes tools
# -----------------------------------------------------------------------------
if [[ "$PHASE" == "all" || "$PHASE" == "node-setup" ]]; then
    echo ""
    log_info "--- Phase 1: Node Setup ---"
    setup_control_plane_node
    for i in $(seq 0 $((WORKER_COUNT - 1))); do
        setup_worker_node "${WORKER_HOSTNAMES[$i]}" "${WORKER_PUBLIC_IPS[$i]}"
    done
fi

# -----------------------------------------------------------------------------
# Phase: init
# Initialise the control plane — kubeadm init, kubectl, Flannel, CNI
# -----------------------------------------------------------------------------
if [[ "$PHASE" == "all" || "$PHASE" == "init" ]]; then
    echo ""
    log_info "--- Phase 2: Control Plane Init ---"
    init_control_plane
    get_join_command
fi

# -----------------------------------------------------------------------------
# Phase: join
# Join all worker nodes to the cluster
# -----------------------------------------------------------------------------
if [[ "$PHASE" == "all" || "$PHASE" == "join" ]]; then
    # If running join standalone, generate a fresh join command
    if [[ "$PHASE" == "join" ]]; then
        get_join_command
    fi
    echo ""
    log_info "--- Phase 3: Join Workers ---"
    join_workers
fi

# -----------------------------------------------------------------------------
# Phase: verify
# Wait for all nodes to report Ready
# -----------------------------------------------------------------------------
if [[ "$PHASE" == "all" || "$PHASE" == "verify" ]]; then
    echo ""
    log_info "--- Phase 4: Verify Cluster ---"
    verify_cluster
fi

echo ""
log_success "Done! [phase: ${PHASE}]"
log_info "Full log available at: $LOG_FILE"
echo ""
