#!/bin/bash -eu

# check root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Install system tools and docker
apt-get update
dpkg --configure -a
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository \
   "deb [arch=arm64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
apt-get update
apt-get install -y docker.io

# Setup daemon.
cat << EOF | tee -a /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

# Restart docker
systemctl daemon-reload
systemctl restart docker
systemctl enable docker.service

# Add pi as docker user
usermod -aG docker ubuntu

# Test docker
echo "Testing docker installation..."
docker pull hello-world >/dev/null
docker run hello-world >/dev/null
docker rmi -f hello-world:latest &>/dev/null 

echo "Docker successfully installed."
