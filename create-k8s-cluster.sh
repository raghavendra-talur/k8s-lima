#!/bin/bash

set -e

if [[ -z "${1}" ]]; then
    echo "Usage: $0 <VM_NAME>"
    exit 1
fi

export VM_NAME="${1}"

limactl disk create ${VM_NAME}-rook --size 20GiB --format raw

limactl create --tty=false --name=${VM_NAME} \
        --set '.additionalDisks[0].name=strenv(VM_NAME) + "-rook"' \
        /Users/rtalur/src/github.com/raghavendra-talur/limaVMs/k8s.yaml

limactl start --tty=false ${VM_NAME}

socket_vmnet_ip=$(limactl shell ${VM_NAME} -- bash -c "ip a | grep 192.168.105 | grep -w inet | awk '{print \$2}' | cut -d"/" -f1")
echo socket_vmnet_ip ${socket_vmnet_ip}

ip=${socket_vmnet_ip}


ssh rtalur@${ip} -- "bash -xc 'sudo cp /home/rtalur.linux/.ssh/authorized_keys /root/.ssh/'"
ssh root@${ip} -- mkdir -p /etc/kubernetes/pki


scp containerd.conf root@${ip}:/tmp/

scp ~/.minikube/ca.crt root@${ip}:/tmp/
scp ~/.minikube/ca.key root@${ip}:/tmp/

scp 99-kubernetes-cri.conf root@${ip}:/tmp/


scp crictl.yaml root@${ip}:/tmp
scp provision-k8s.sh root@${ip}:/tmp/

ssh root@${ip} -- bash -xc 'date'
ssh root@${ip} -- "bash -xc 'chmod +x /tmp/provision-k8s.sh'"
ssh root@${ip} -- "bash -xc '/tmp/provision-k8s.sh'"


scp root@${ip}:/etc/kubernetes/admin.conf ~/${VM_NAME}.kubeconfig
sed -i "s/server: https:\/\/[0-9.]*:6443/server: https:\/\/${ip}:6443/" ~/${VM_NAME}.kubeconfig
unset KUBECONFIG
kconf add -n ${VM_NAME} ~/${VM_NAME}.kubeconfig

exit 0
