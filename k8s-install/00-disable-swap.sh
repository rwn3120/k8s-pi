#!/bin/bash -eu

echo "Disabling swap"
sudo dphys-swapfile swapoff
echo "Uninstalling swap"
sudo dphys-swapfile uninstall
sudo update-rc.d dphys-swapfile remove
sudo apt-get purge dphys-swapfile
