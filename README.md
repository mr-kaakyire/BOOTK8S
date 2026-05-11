# BOOTK8S

A bash script that automates standing up a multi-node Kubernetes cluster from scratch. You fill in a YAML config file with your node IPs and SSH key, run one command on the control plane, and walk away with a working cluster.
The script takes care of preparing each machine — things like setting hostnames, disabling swap, configuring kernel networking settings, and installing the required packages — then initialises the control plane, installs the pod network, and joins all your worker nodes automatically.

---

## Goals and Design Philosophy
Setting up Kubernetes the hard way is a humbling experience. After going through the process manually — configuring nodes one by one, debugging networking issues, chasing down the right package versions — the natural next thought is: there has to be a better way to do this.
Most cloud providers offer managed Kubernetes solutions (EKS, GKE, AKE) that abstract all of this away. But managed solutions come with a price tag that adds up quickly, especially for personal projects, learning environments, or teams that just want full control over their infrastructure without paying a premium for it.
I looked around for tools that fully automate bare Kubernetes cluster setup on your own infrastructure. Maybe I didn't look hard enough — or maybe I just wanted to build it myself and learn in the process. Either way, BOOTK8S was born out of that gap.
This project was built alongside my own learning journey with Kubernetes. Every problem the script solves is a problem I actually ran into. Every fix documented here is a fix I had to figure out myself. Because of that, the project is intentionally beginner friendly — the README doesn't just tell you what to do, it explains why each step exists and what goes wrong when it doesn't happen correctly.

The script is designed to be:

- **Cloud agnostic** — works on AWS, GCP, Azure, DigitalOcean, Hetzner, Contabo, Linode, on-premise bare metal, or local VMs. It makes no assumptions about the underlying infrastructure
- **Linux flavour agnostic** — works on any Debian-based distribution. The only requirement is that the OS uses `apt` as its package manager
- **Idempotent** — safe to rerun at any point without causing duplicate or broken state
- **Recoverable** — if something fails, you can rerun just the phase that failed rather than starting from scratch

> **Recommended setup:** Debian Trixie (Debian 13) on AWS EC2. This is the combination the script was developed and tested on. Ubuntu 20.04, 22.04, and 24.04 should work without modification.

---

## What It Does

Running the script on your control plane will:

1. Configure all nodes — sets hostnames, updates `/etc/hosts`, disables swap, loads required kernel modules, and configures network settings
2. Install `containerd` as the container runtime on all nodes
3. Install `kubelet`, `kubeadm`, and `kubectl` on all nodes
4. Initialise the control plane with `kubeadm init`
5. Install Flannel as the pod network (CNI)
6. Fix the CNI plugin path for Flannel compatibility
7. Join all worker nodes to the cluster
8. Verify all nodes reach `Ready` status

Worker nodes are configured remotely over SSH — you only need to run the script once, from the control plane.

---

## Project Structure

```
k8s-setup/
├── setup-cluster.sh       # Main entry point
├── cluster-config.yaml    # Your cluster configuration
└── lib/
    ├── common.sh          # Logging helpers and run_step utility
    ├── parse.sh           # Config parsing and validation
    ├── ssh.sh             # SSH connectivity and remote execution
    ├── node.sh            # Node setup for control plane and workers
    ├── init.sh            # Control plane initialisation
    ├── join.sh            # Worker node joining
    └── verify.sh          # Cluster verification
```

---

## Platform Compatibility

### Supported Platforms

The script works on any infrastructure that meets the following conditions:

- The OS uses `apt` as its package manager (Debian, Ubuntu, and their derivatives)
- All nodes can reach each other over a network
- The control plane can SSH into all worker nodes using a private key
- Nodes have internet access to pull packages from the Kubernetes and Debian/Ubuntu apt repositories

This includes:

- **Any major cloud provider** — AWS, GCP, Azure, DigitalOcean, Hetzner, Contabo, Linode, Vultr, etc.
- **On-premise bare metal servers**
- **Local virtual machines** — VirtualBox, VMware, Proxmox

### Non-apt Distributions

If your infrastructure uses a non-`apt` based Linux distribution (RHEL, CentOS, Fedora, Arch), the package installation steps in `lib/node.sh` will need to be adapted to use the appropriate package manager (`yum`, `dnf`, `pacman`). All OS configuration steps and Kubernetes setup logic are otherwise universal.

---

## Prerequisites

### Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 2GB per node | 4GB+ per node |
| CPU | 2 vCPUs per node | 4 vCPUs per node |
| Disk | 20GB per node | 50GB+ per node |
| Nodes | 2 (1 control plane + 1 worker) | 3+ (1 control plane + 2+ workers) |

> `kubeadm init` will hard-fail if the control plane has less than 1700MB of available RAM. Always use at least a 2GB instance.

### Network Requirements

All nodes must be able to reach each other over a network. The following ports must be open between nodes before running the script:

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 6443 | TCP | Workers → Control plane | Kubernetes API server |
| 10250 | TCP | Control plane → Workers | Kubelet API (used by control plane to reach worker kubelets) |
| 30000–32767 | TCP | External → Workers | NodePort services |

How you open these ports depends on your platform:

- **AWS** — configure Security Group inbound rules using your VPC's private CIDR (e.g. `172.31.0.0/16`) as the source for internal ports
- **GCP** — configure VPC firewall rules
- **DigitalOcean** — configure Cloud Firewalls or droplet-level `ufw` rules
- **On-premise / bare metal** — configure `ufw`, `iptables`, or your network firewall

> Never use public IPs as the source for internal cluster ports. All node-to-node cluster traffic should travel over the private network.

### Operating System

- A Debian-based Linux distribution with `apt`
- A user that can `sudo` to root, or direct root access
- `bash`, `curl`, `wget`, and `ssh` client installed (present by default on most distributions)

### Software on the Control Plane

The script installs everything it needs automatically, including `yq` (the YAML parser used to read the config file). The only tools required before running are:

- `bash` 4.0+
- `wget`
- `curl`
- `ssh` client

---

## SSH Key Setup

The script SSHes from the control plane into each worker node to run setup commands remotely. For this to work, **the SSH key specified in the config must be authorised on every node in the cluster**.

### What "Authorised" Means

When SSH connects to a machine, the remote machine checks whether the connecting key's public counterpart is listed in `~/.ssh/authorized_keys`. If it is, access is granted without a password. The script uses a single `.pem` key to access all workers — so that key's public counterpart must be in the `authorized_keys` file of the SSH user on every worker node.

### On AWS

AWS handles this automatically. When you launch EC2 instances and assign the same key pair to all of them, AWS injects the public key into `~/.ssh/authorized_keys` on every instance at boot. As long as all your nodes were launched with the same key pair, no extra steps are needed.

### On Other Platforms

If your cloud provider or infrastructure does not automatically inject SSH keys, you need to manually authorise the key on each node.

**Step 1 — Extract the public key from your `.pem` file:**
```bash
ssh-keygen -y -f /path/to/your-key.pem
```
This prints the public key to your terminal.

**Step 2 — Add it to each node's `authorized_keys`:**
```bash
# On each node
mkdir -p ~/.ssh
echo "YOUR_PUBLIC_KEY_HERE" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
chmod 700 ~/.ssh
```

Or do it in one command from a machine that already has access:
```bash
ssh-copy-id -i /path/to/your-key.pem user@<node-ip>
```

**Step 3 — Verify it works:**
```bash
ssh -i /path/to/your-key.pem user@<node-ip> "echo ok"
```

If this prints `ok` without a password prompt, the key is correctly authorised.

### Key Permissions

The `.pem` key file must have restricted permissions or SSH will refuse to use it:

```bash
chmod 400 /path/to/your-key.pem
```

### Key Location

The `.pem` file must exist on the **control plane** at the path you specify in `cluster-config.yaml`. It does not need to be present on worker nodes.

> The script runs an SSH connectivity check against all worker nodes before doing anything else. It will exit immediately if any node cannot be reached, protecting you from a partial setup.

---

## Configuration

Edit `cluster-config.yaml` before running. All fields are required.

```yaml
cluster:
  pod_network_cidr: 10.244.0.0/16   # Must match Flannel's expected CIDR — do not change
  kubernetes_version: v1.32          # Kubernetes version to install

ssh:
  key_path: /home/admin/.ssh/kube-node-key.pem   # Path to .pem key on the control plane
  user: admin                                     # SSH user on worker nodes

nodes:
  control_plane:
    hostname: k8s-control-plane
    public_ip: 3.134.90.138       # Used for SSH connectivity check only
    private_ip: 172.31.45.208     # Used for all internal cluster traffic

  workers:
    - hostname: k8s-worker-01
      public_ip: 3.137.203.9
      private_ip: 172.31.35.229

    - hostname: k8s-worker-02
      public_ip: 3.144.164.29
      private_ip: 172.31.39.154
```

### SSH User

The `ssh.user` field should match the default SSH user for your OS and platform:

| Platform / OS | Default SSH user |
|---------------|-----------------|
| AWS — Debian | `admin` |
| AWS — Ubuntu | `ubuntu` |
| AWS — Amazon Linux | `ec2-user` |
| GCP — Debian/Ubuntu | your Google account username |
| DigitalOcean | `root` |
| Hetzner | `root` |
| On-premise / custom | whatever user you created |

The script SSHes in as this user and immediately switches to `root` for all operations. The user must have `sudo` privileges.

### Public vs Private IPs

This distinction is critical and a common source of errors:

- **`private_ip`** — used in `/etc/hosts` and passed to `kubeadm init`. All cluster traffic travels over the private network. If this is wrong, the join command will point at the wrong address and workers will fail to join
- **`public_ip`** — only used by the script to SSH into worker nodes during setup. Once setup is complete, public IPs are never used by Kubernetes

NOTE: If your nodes don't exist in the same local network, use the same publicIP for both fields.

Before running the script, verify each node's private IP with:
```bash
hostname -I
```

### Adding More Workers

Add as many workers as needed under the `workers` list. The script automatically detects and configures any number of workers:

```yaml
workers:
  - hostname: k8s-worker-01
    public_ip: 3.137.203.9
    private_ip: 172.31.35.229

  - hostname: k8s-worker-02
    public_ip: 3.144.164.29
    private_ip: 172.31.39.154

  - hostname: k8s-worker-03
    public_ip: 3.150.100.50
    private_ip: 172.31.40.200
```

---

## Usage

Upload the entire `k8s-setup/` folder to your control plane, then:

```bash
# Make the script executable
chmod +x setup-cluster.sh

# Run the full setup — must be run as root
sudo ./setup-cluster.sh cluster-config.yaml
```

### Running a Specific Phase

If the script fails partway through, you can rerun just the phase that failed instead of starting from scratch:

```bash
sudo ./setup-cluster.sh cluster-config.yaml --phase node-setup
sudo ./setup-cluster.sh cluster-config.yaml --phase init
sudo ./setup-cluster.sh cluster-config.yaml --phase join
sudo ./setup-cluster.sh cluster-config.yaml --phase verify
```

| Phase | What it does |
|-------|-------------|
| `node-setup` | Configures OS, installs containerd and Kubernetes tools on all nodes |
| `init` | Runs `kubeadm init`, configures kubectl, installs Flannel, fixes CNI path |
| `join` | Joins all worker nodes to the cluster |
| `verify` | Waits for all nodes to report `Ready` |

---

## Idempotency

The script is safe to rerun at any point. Every step checks whether it has already been completed before running again:

| Step | How it's idempotent |
|------|---------------------|
| `/etc/hosts` update | Checks for the comment marker before appending |
| Kubernetes tools install | Checks if `kubelet` is already in PATH before installing |
| `kubeadm init` | Skipped if `/etc/kubernetes/admin.conf` already exists |
| CNI symlinks | Uses `ln -sf` to force overwrite without error |
| Worker join | Checks for `/etc/kubernetes/kubelet.conf` before joining |
| Worker join (partial state) | Automatically runs `kubeadm reset` to clean up any partial state before rejoining |

---

## Logs

All output from every step is appended to:

```
/var/log/k8s-setup.log
```

If a step fails, the terminal will show which step failed and point you to the log:

```
[✗] Running kubeadm init
[✗] Failed at: Running kubeadm init
[✗] See /var/log/k8s-setup.log for details
```

Each run appends to the log rather than overwriting it so you keep a full history across reruns. To follow the log live in a separate terminal while the script runs:

```bash
tail -f /var/log/k8s-setup.log
```

---

## After Setup

Once the script completes, set up `kubectl` access for your non-root user on the control plane:

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Then verify your cluster:

```bash
kubectl get nodes
```

Expected output:
```
NAME                STATUS   ROLES           AGE   VERSION
k8s-control-plane   Ready    control-plane   5m    v1.32.13
k8s-worker-01       Ready    <none>          3m    v1.32.13
k8s-worker-02       Ready    <none>          3m    v1.32.13
```

---

## Known Issues and Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| `gpg: command not found` | `gnupg` not installed before adding the apt key | Script now runs `apt-get update` before installing `gnupg` |
| Workers can't join — connection timeout on port 6443 | Firewall or Security Group blocking port 6443 | Open TCP 6443 from your private network CIDR to the control plane |
| Join command points at wrong IP | Wrong `private_ip` in config | Verify `private_ip` fields match `hostname -I` output on each node |
| kubelet crash loop — `config.yaml` not found | `kubeadm init` didn't complete or files were deleted | Run `kubeadm reset -f` then rerun with `--phase init` |
| Flannel error — `failed to find plugin in path [/usr/lib/cni]` | CNI plugins installed to `/opt/cni/bin` but Flannel looks in `/usr/lib/cni` | Handled automatically by the script — symlinks `/opt/cni/bin/*` into `/usr/lib/cni/` |
| Kubernetes apt repo rejected on Debian Trixie | v1.29 uses deprecated GPG v3 signatures | Use v1.32 or later |
| `kubectl` connection refused on port 8080 | kubeconfig not configured for current user | Copy `admin.conf` to `~/.kube/config` as shown in the After Setup section |
| SSH permission denied | `.pem` file permissions too open | Run `chmod 400 /path/to/key.pem` |
| SSH key not authorised on worker | Public key not in worker's `authorized_keys` | See the SSH Key Setup section |

---

## Kubernetes Version

The default version is **v1.32**. To use a different version update `cluster.kubernetes_version` in `cluster-config.yaml`.

> Do not use versions older than v1.30 on Debian Trixie — they use deprecated GPG signatures that are rejected by the system.
