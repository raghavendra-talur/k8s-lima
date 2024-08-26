#!/bin/bash

set -eux -o pipefail

export KUBECONFIG=/etc/kubernetes/admin.conf
#export userv2IP=$(ip a | grep 192.168.104 | grep inet | awk '{print $2}' | cut -d"/" -f1)
#export vzNatIP=$(ip a | grep 192.168.106 | grep -w inet | awk '{print $2}' | cut -d"/" -f1)
export socketVMNetIP=$(ip a | grep 192.168.105 | grep -w inet | awk '{print $2}' | cut -d"/" -f1)
export socketVMNetInterface=$(ip a | grep 192.168.105 | grep -w inet | awk '{print $10}')
export hostname=$(hostname)
export otherhostname="${hostname#lima-}"
export k8sIP=${socketVMNetIP}
export k8sinterface="${socketVMNetInterface}"

#echo "userv2IP: ${userv2IP}"
#echo "vzNatIP: ${vzNatIP}"
echo "socketVMNetIP: ${socketVMNetIP}"
echo "hostname: ${hostname}"
echo "otherhostname: ${otherhostname}"

# Make sure kernel modules required by containerd are loaded
cat /tmp/containerd.conf | tee /etc/modules-load.d/containerd.conf

# Configure network for kubernetes
cat /tmp/99-kubernetes-cri.conf | tee /etc/sysctl.d/99-kubernetes-cri.conf
sysctl --system

# Ensure kubernetes uses the certificates we provide
mkdir -p /etc/kubernetes/pki
cp /tmp/ca.crt /etc/kubernetes/pki
cp /tmp/ca.key /etc/kubernetes/pki


# Update the system packages list
apt-get update

# Install the required packages
apt-get install -y apt-transport-https ca-certificates curl net-tools iptables


# Installing kubeadm, kubelet and kubectl
export DEBIAN_FRONTEND=noninteractive
VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt | sed -e 's/v//' | cut -d'.' -f1-2)
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
apt-get update

#containerd
apt-get install -y containerd
mkdir -p /etc/containerd
cat <<EOF >>/etc/containerd/config.toml
  version = 2
  [proxy_plugins]
    [proxy_plugins."stargz"]
      type = "snapshot"
      address = "/run/containerd-stargz-grpc/containerd-stargz-grpc.sock"
EOF
systemctl enable --now containerd

# cri-tools
apt-get install -y cri-tools
cat /tmp/crictl.yaml > /etc/crictl.yaml


# cni-plugins
apt-get install -y kubernetes-cni
rm -f /etc/cni/net.d/*.conf*
apt-get install -y kubelet kubeadm kubectl && apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

mkdir -p /etc/containerd
cat <<EOF >>/etc/containerd/config.toml
  [plugins]
    [plugins."io.containerd.grpc.v1.cri"]
      sandbox_image = "$(kubeadm config images list | grep pause | sort -r | head -n1)"
      device_ownership_from_security_context = true
      [plugins."io.containerd.grpc.v1.cri".containerd]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
            runtime_type = "io.containerd.runc.v2"
            [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
              SystemdCgroup = true
EOF
systemctl restart containerd


kubeadm config images list
kubeadm config images pull --cri-socket=unix:///run/containerd/containerd.sock
# Initializing your control-plane node
cat <<EOF >kubeadm-config.yaml
kind: InitConfiguration
apiVersion: kubeadm.k8s.io/v1beta3
localAPIEndpoint:
  advertiseAddress: "${k8sIP}"
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    node-ip: ${k8sIP}
---
kind: ClusterConfiguration
apiVersion: kubeadm.k8s.io/v1beta3
apiServer:
  extraArgs:
    advertise-address: "0.0.0.0"
  certSANs: # --apiserver-cert-extra-sans
  - "127.0.0.1"
  - "${k8sIP}"
  - "${hostname}"
  - "${otherhostname}"
networking:
  podSubnet: "10.244.0.0/16" # --pod-network-cidr
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
EOF
kubeadm init --config kubeadm-config.yaml
# Installing a Pod network add-on
#kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.24.0/kube-flannel.yml

## Download the Flannel YAML file
wget https://github.com/flannel-io/flannel/releases/download/v0.24.0/kube-flannel.yml -O kube-flannel.yml

## Edit the YAML file to specify the interface
sed -i "s/--kube-subnet-mgr/--kube-subnet-mgr\n        - --iface=${k8sinterface}/" kube-flannel.yml

## Apply the modified YAML file
kubectl apply -f kube-flannel.yml

# Control plane node isolation
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# add back to the certSANs
#- "${userv2IP}"



test -e /root/hostpath.completed && exit 0
# Download the local-path-provisioner deployment and service YAML from Rancher
wget https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml -O local-path-storage.yaml
# Modify the StorageClass in the YAML:
# - Change the name to 'standard'
sed -i 's/^  name: local-path$/  name: standard/g' local-path-storage.yaml
# Apply the modified YAML
kubectl apply -f local-path-storage.yaml
kubectl annotate sc/standard storageclass.kubernetes.io/is-default-class="true"
KUBE_VERSION="${1:-1.30.0}"
function log {
  echo "=====  $*  ====="
}
# Determine the Kube minor version
[[ "${KUBE_VERSION}" =~ ^[0-9]+\.([0-9]+) ]] && KUBE_MINOR="${BASH_REMATCH[1]}" || exit 1
log "Detected kubernetes minor version: ${KUBE_MINOR}"
TAG="v7.0.1"  # https://github.com/kubernetes-csi/external-snapshotter/releases
log "Deploying external snapshotter: ${TAG}"
kubectl create -k "https://github.com/kubernetes-csi/external-snapshotter/client/config/crd?ref=${TAG}"
kubectl create -n kube-system -k "https://github.com/kubernetes-csi/external-snapshotter/deploy/kubernetes/snapshot-controller?ref=${TAG}"
# Install the hostpath CSI driver
# https://github.com/kubernetes-csi/csi-driver-host-path/releases
HP_BASE="$(mktemp --tmpdir -d csi-driver-host-path-XXXXXX)"
TAG="v1.12.1"
DEPLOY_SCRIPT="deploy.sh"
log "Deploying CSI hostpath driver: ${TAG}"
git clone --depth 1 -b "$TAG" https://github.com/kubernetes-csi/csi-driver-host-path.git "$HP_BASE"
DEPLOY_PATH="${HP_BASE}/deploy/kubernetes-1.${KUBE_MINOR}/"
# For versions not yet supported, use the latest
if [[ ! -d "${DEPLOY_PATH}" ]]; then
  DEPLOY_PATH="${HP_BASE}/deploy/kubernetes-latest/"
fi
# Remove the CSI testing manifest. It exposes csi.sock as a TCP socket using
# socat. This is insecure, but the larger problem is that it pulls the socat
# image from docker.io, making it subject to rate limits that break this script.
rm -f "${DEPLOY_PATH}/hostpath/csi-hostpath-testing.yaml"
"${DEPLOY_PATH}/${DEPLOY_SCRIPT}"
rm -rf "${HP_BASE}"
CSI_DRIVER_NAME="hostpath.csi.k8s.io"
log "Creating StorageClass for CSI hostpath driver"
kubectl apply -f - <<SC
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: csi-hostpath-sc
provisioner: hostpath.csi.k8s.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
SC
touch /root/hostpath.completed

# Submariner
node=$(kubectl get nodes -o name | cut -d"/" -f2)
kubectl annotate node $node gateway.submariner.io/public-ip=ipv4:${k8sIP}

mkdir -p /data

kubectl get cm -n kube-system kube-proxy -o yaml | sed 's/masqueradeAll: false/masqueradeAll: true/g' > kubeproxy
kubectl apply -f kubeproxy
kubectl delete pod -n kube-system -l k8s-app=kube-proxy