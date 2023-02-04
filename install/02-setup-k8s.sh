#!/bin/bash -eu

# check root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#ensure-iptables-tooling-does-not-use-the-nftables-backend
echo "Switching to iptables-legacy"
update-alternatives --set iptables /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#installing-kubeadm-kubelet-and-kubectl
echo "Installing K8s"
apt-get update && apt-get install -y apt-transport-https curl
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF | tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet kubeadm kubectl

apt-mark hold kubelet kubeadm kubectl

if hostname | grep -E '\-master$' > /dev/null; then 
    echo "Initializing K8s master node"
    kubeadm init --pod-network-cidr="192.168.0.0/16"

    echo "Setting up kubectl"
    mkdir -p "/home/ubuntu/.kube"
    cp -i "/etc/kubernetes/admin.conf" "/home/ubuntu/.kube/config"
    chown "ubuntu:ubuntu" "/home/ubuntu/.kube/config"

    echo "Installing CNI"
    kubectl apply -f "https://docs.projectcalico.org/v3.11/manifests/calico.yaml"
    kubectl -n kube-system set env "daemonset/calico-node FELIX_IGNORELOOSERPF=true" # https://github.com/kubernetes-sigs/kind/issues/891
    echo "Deploying Traefik Ingress Controller"
    # https://docs.traefik.io/v1.7/user-guide/kubernetes/
    kubectl apply -f "https://raw.githubusercontent.com/containous/traefik/v1.7/examples/k8s/traefik-rbac.yaml"
    kubectl apply -f "https://raw.githubusercontent.com/containous/traefik/v1.7/examples/k8s/traefik-ds.yaml"
    echo "Done. K8s cluster is ready. Now it's a time to add some worker nodes."
else
    echo "Initializing K8s worker node"
    MASTER_NODE=$(grep -Ei 'master\s*$' /etc/hosts | head -1 | awk '{print $1}')
    echo "Joining to K8s (master: ${MASTER_NODE})"
    SSH_COMMAND="ssh -i /home/ubuntu/.ssh/id_rsa -o StrictHostKeyChecking=no ubuntu@${MASTER_NODE}"
    $(${SSH_COMMAND} kubeadm token create --print-join-command)
    echo "Assigning a 'worker' role to $(hostname)" 
    ${SSH_COMMAND} kubectl label node "$(hostname)" "node-role.kubernetes.io/worker=worker"
    echo "Done. Worker $(hostname) sucessfully joined to K8s cluster."
fi
