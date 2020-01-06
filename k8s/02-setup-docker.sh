#!/bin/bash -eu

sudo docker pull hello-world
sudo docker run hello-world
sudo usermod -aG docker pi
