# Run k8s on your Raspberry Pi

Please note that this pet project is still at WIP phase.

## 3 node setup

You will need:
- 3x Raspberry Pi 3/4
- 3x MicroSD card (8GB+)
- 3x power supply (3A)
- 3x network cables
- 1x router

Cluster description (colors are matching colored network cables in my cluster):
- 3 nodes
  - 1 master: green-master
  - 2 workers: yellow-worker, red-worker

### Load image to MicroSD cards
- put MicroSD card for `green-master` node into your PC and run (tested on Debian)
```
sudo ./k8s-pi.sh green-master <device path> --add-pub-key=<public SSH key path> --gpu-memory=16

example:
sudo ./k8s-pi.sh green-master /dev/mmcblk0 --skip-flash --add-pub-key=/home/radowan/.ssh/id_rsa.pub --gpu-memory=16
```
- replace MicroSD card with MicroSD card for `yellow worker` and run
```
sudo ./k8s-pi.sh yellow-worker <device path> --add-pub-key=<public SSH key path> --gpu-memory=16
```
- replace MicroSD card with MicroSD card for `red worker` into your PC and run
```
sudo ./k8s-pi.sh red-worker <device path> --add-pub-key=<public SSH key path> --gpu-memory=16
```
- insert MicroSD card to Raspberry Pis

### Setup network
- setup router to run DHCP server
- connect all Raspberry Pis to router
- turn on all Raspberry Pis
- login to your router as admin 
  - setup static IP allocation for all Raspbery Pis
    - see `cluster_hosts` file:
```
192.168.0.1     green-master
192.168.0.2     yellow-worker
192.168.0.3     red-worker 
```

### Setup k8s (WIP)
- connect your PC to router
- setup k8s on `green-master`
```
ssh pi@192.168.0.1 k8s/install.sh
```
- store output and setup k8s on `yellow-worker` and `red-worker`
```
ssh pi@192.168.0.1 k8s/install.sh
ssh pi@192.168.0.1 k8s/install.sh
```
