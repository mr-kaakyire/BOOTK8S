#!/bin/bash
# =============================================================================
# node.sh — Node setup for both control plane and workers
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"

# Build the /etc/hosts block containing all node IPs and hostnames
build_hosts_block() {
    local block="# Kubernetes cluster nodes
${CP_PRIVATE_IP}    ${CP_HOSTNAME}"

    for i in $(seq 0 $((WORKER_COUNT - 1))); do
        block="${block}
${WORKER_PRIVATE_IPS[$i]}    ${WORKER_HOSTNAMES[$i]}"
    done

    echo "$block"
}

# Generate the node setup script as a string
# Used for workers — piped over SSH and executed as root
# All steps are idempotent — safe to rerun
node_setup_script() {
    local hostname="$1"
    local hosts_block="$2"

    cat <<NODEEOF
set -euo pipefail

# 1. Copy SSH keys from admin to root
mkdir -p /root/.ssh
cp /home/admin/.ssh/authorized_keys /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# 2. Set hostname
hostnamectl set-hostname ${hostname}

# 3. Update /etc/hosts — skip if already added
grep -qF '# Kubernetes cluster nodes' /etc/hosts || echo "${hosts_block}" >> /etc/hosts

# 4. Disable swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 5. Load kernel modules
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter

# 6. Configure network settings
printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/k8s.conf
sysctl --system

# 7. Update apt cache, then install gnupg and containerd
apt-get update -q
apt-get install -y -q gnupg containerd

# 8. Configure containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# 9. Install Kubernetes tools — skip if already installed
if ! command -v kubelet &>/dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

    apt-get update -q
    apt-get install -y -q kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
else
    echo "Kubernetes tools already installed, skipping"
fi
NODEEOF
}

# Setup control plane node — runs locally as root
setup_control_plane_node() {
    log_info "Setting up node: $CP_HOSTNAME (control plane)"
    local hosts_block
    hosts_block=$(build_hosts_block)

    run_step "Copying SSH keys"            "cp /home/admin/.ssh/authorized_keys /root/.ssh/authorized_keys"
    run_step "Setting hostname"            "hostnamectl set-hostname $CP_HOSTNAME"
    run_step "Updating /etc/hosts"         "grep -qF '# Kubernetes cluster nodes' /etc/hosts || printf '\n${hosts_block}\n' >> /etc/hosts"
    run_step "Disabling swap"              "swapoff -a && sed -i '/ swap / s/^\(.*\)\$/#\1/g' /etc/fstab"
    run_step "Loading kernel modules"      "printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf && modprobe overlay && modprobe br_netfilter"
    run_step "Configuring network"         "printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/k8s.conf && sysctl --system"
    run_step "Updating apt cache"          "apt-get update -q"
    run_step "Installing gnupg"            "apt-get install -y -q gnupg"
    run_step "Installing containerd"       "apt-get install -y -q containerd"
    run_step "Configuring containerd"      "mkdir -p /etc/containerd && containerd config default > /etc/containerd/config.toml && sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml && systemctl restart containerd && systemctl enable containerd"

    if ! command -v kubelet &>/dev/null; then
        run_step "Adding Kubernetes apt repo"  "mkdir -p /etc/apt/keyrings && curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg && echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list"
        run_step "Installing Kubernetes tools" "apt-get update -q && apt-get install -y -q kubelet kubeadm kubectl && apt-mark hold kubelet kubeadm kubectl"
    else
        log_warn "Kubernetes tools already installed, skipping"
    fi

    log_success "Control plane node setup complete"
}

# Setup a worker node — runs over SSH, switches to root
setup_worker_node() {
    local hostname="$1"
    local public_ip="$2"
    local hosts_block
    hosts_block=$(build_hosts_block)
    local script
    script=$(node_setup_script "$hostname" "$hosts_block")

    log_info "Setting up node: $hostname ($public_ip)"

    if run_remote "$public_ip" "$script"; then
        log_success "Node setup complete: $hostname"
    else
        log_error "Node setup failed: $hostname — see $LOG_FILE"
        exit 1
    fi
}
