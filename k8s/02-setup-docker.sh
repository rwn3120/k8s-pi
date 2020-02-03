#!/bin/bash -eu

# Setup daemon.
cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
# Restart docker.
systemctl daemon-reload
systemctl restart docker
# Add pi as docker user
sudo usermod -aG docker pi
# Test docker
sudo docker pull hello-world
sudo docker run hello-world
sudo docker rmi -f hello-world:latest
