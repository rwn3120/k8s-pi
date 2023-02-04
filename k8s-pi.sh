#!/bin/bash -eu

# check root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# variables
BIN=$(basename "${0}" | sed 's/\..*//')
DIR=$(dirname $(readlink -f "${0}"))
K8S_INSTALL="${DIR}/install"
EXAMPLES="${DIR}/examples"
IMAGE_URL=${IMAGE_URL:-"http://cdimage.ubuntu.com/releases/19.10.1/release/ubuntu-19.10.1-preinstalled-server-arm64+raspi3.img.xz"}
WORK_DIRECTORY="/tmp/${BIN}"
CLUSTER_HOSTS_FILE="${DIR}/cluster_hosts"
NO_CACHE="false"
SKIP_FLASH="false"

# usage
usage() {
    cat << EOL
${BIN} - an utility for creating Raspberry PI card

Usage:
    ${BIN} [OPTIONS] <node-name> <device>

Options:
    --cluster-hosts=<value>      ... file with cluster hosts (default cluster-hosts="${CLUSTER_HOSTS_FILE}")
    --image-url=<value>          ... image URL (default --image-url="${IMAGE_URL}")
    --work-directory=<value>     ... working directory (default --work-directory="${WORK_DIRECTORY}")
    --add-pub-key=<value>        ... public key to add to authorized_keys
    --gpu-memory=<value>         ... GPU memory to use (values 16, 64, 128, 256, 512)
    --no-cache                   ... force to download the image
    --http-proxy                 ... use http proxy
    --skip-flash                 ... skip writting image to device
Example:
    ${BIN} green-master /dev/mmcblk0
    ${BIN} --cluster-hosts=./cluster_hosts --http-proxy="http://my-company-proxy.com:80/" green-master /dev/mmcblk0
EOL
}

# parse arguments
NODE=""
DEVICE=""
PUB_KEY=""
GPU_MEMORY=""
HTTP_PROXY=""
for ARG in "${@}"; do
    ARG_VALUE="${ARG#*=}"
    case "${ARG}" in
        -h | --help | -?)
            usage
            exit 1;;
        --cluster-hosts=*)
            CLUSTER_HOSTS_FILE="${ARG_VALUE}";;
        --work-directory=*)
            WORK_DIRECTORY="${ARG_VALUE}";;
        --image-url=*)
            IMAGE_URL="${ARG_VALUE}";;
        --no-cache)
            NO_CACHE="true";;
        --skip-flash)
            SKIP_FLASH="true";;
        --add-pub-key=*)
            PUB_KEY="${ARG_VALUE}";;
        --gpu-memory=*)
            GPU_MEMORY="${ARG_VALUE}";;
        --http-proxy=*)
            HTTP_PROXY="${ARG_VALUE}";;
        --*)
            echo "${ARG} not supported. Run with -h to display usage." >&2
            exit 2;;
        *)
            if [[ "${NODE}" == "" ]]; then
                NODE="${ARG}"
            elif [[ "${DEVICE}" == "" ]]; then
                DEVICE="${ARG}"
            fi;; 
        esac
done

if [[ ! -d "${K8S_INSTALL}" ]]; then
    echo "Missing ${K8S_INSTALL} directory!" >&2
    exit 254
fi

# validate arguments
if [[ ! -f "${CLUSTER_HOSTS_FILE}" ]]; then
    echo "${CLUSTER_HOSTS_FILE} does not exist or is not a file" >&2
    exit 253
fi
if ! grep -iE '\-master$' "${CLUSTER_HOSTS_FILE}" >/dev/null; then 
    echo "${CLUSTER_HOSTS_FILE} does not contain master node" >&2
fi

if [[ "${NODE}" == "" ]]; then
    echo "Missing argument <node>. Run with -h to display usage." >&2
    exit 252
fi
NODE_IP="$(grep "${NODE}" "${CLUSTER_HOSTS_FILE}" || echo "" | awk '{print $1}')"
if [[ "${NODE_IP}" == "" ]]; then
    echo "Node ${NODE} is missing at ${CLUSTER_HOSTS_FILE} or does not have any IP assigned" >&2
    exit 251
fi
if [[ "${DEVICE}" == "" ]]; then
    echo "Missing argument <device>. Run with -h to display help." >&2
    exit 250
elif [[ ! -b "${DEVICE}" ]]; then
    echo "${DEVICE} does not exist or is not a block device!" >&2
    exit 249
fi
PUB_KEY=$(echo "${PUB_KEY}" | sed 's#~#'"${HOME}"'#')
if [[ "${PUB_KEY}" != "" ]] && [[ ! -f "${PUB_KEY}" ]]; then
    echo "${PUB_KEY} does not exist or is not a file" >&2
    exit 248
fi
case "${GPU_MEMORY}" in 
    ""|16|64|128|256|512)
        ;;
    *)
        echo "Invalid GPU memory: ${GPU_MEMORY}. Run with -h to display usage."
        exit 247;;
esac
# BFU check 
if [[ $(basename "${DEVICE}") =~ (sd.*|nvm.*|loop.*) ]]; then
    if [[ ${FORCE:-"false"} != "true" ]]; then
        echo "export FORCE=true to write to ${DEVICE}" >&2
        exit 246
    fi
fi

# unmount device
MOUNT_POINTS=($(df | grep -E "^${DEVICE}" | sed 's/.*% //'))
if [[ ${#MOUNT_POINTS[@]} -gt 0 ]]; then
    read -p "Continue and unmount ${DEVICE}? [y/N] " -n 1 -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "\nCancelled"
        exit 245
    fi
    echo
    for MOUNT_POINT in "${MOUNT_POINTS[@]}"; do
        umount "${MOUNT_POINT}"
    done
fi

# flash device with image
if [[ "${SKIP_FLASH}" == "false" ]]; then
    # download image
    mkdir -p "${WORK_DIRECTORY}"
    IMAGE_FILE="${WORK_DIRECTORY}/$(basename "${IMAGE_URL}" "$(basename "${IMAGE_URL}")")"
    if [[ ! -f "${IMAGE_FILE}" ]] || [[ "${NO_CACHE}" == "true" ]]; then
        echo "Downloading ${IMAGE_URL}"
        wget -q --show-progress "${IMAGE_URL}" -O "${IMAGE_FILE}"
    fi
    # write image to device
    if [[ "${FORCE:-false}" != "true" ]]; then
        read -p "Do you really want to write ${IMAGE_FILE} to ${DEVICE}? [y/N] " -n 1 -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "\nCancelled"
            exit 244
        fi
        echo
    fi
    echo "Writting ${IMAGE_FILE} to ${DEVICE}"
    xzcat "${IMAGE_FILE}" | sudo dd of="${DEVICE}" bs=32M status=progress
    sync
    # resize partition to max
    parted -s "${DEVICE}" resizepart 2 100%
fi

# mount Raspberry Pi storage
echo "Mounting ${DEVICE} to ${WORK_DIRECTORY}/mnt"
PI_BOOT="${WORK_DIRECTORY}/mnt/boot"
PI_ROOT="${WORK_DIRECTORY}/mnt/root"
mkdir -p "${PI_BOOT}" "${PI_ROOT}"
mount "${DEVICE}p1" "${PI_BOOT}"
mount "${DEVICE}p2" "${PI_ROOT}"

# setup network 
echo "Setting up network (DHCP)"
sed -i 's/ubuntu/'"${NODE}"'/g' "${PI_ROOT}/etc/hostname" "${PI_ROOT}/etc/hosts"
cat "${CLUSTER_HOSTS_FILE}" | grep -v -E '(^\s*#.*$|^\s*$)' >> "${PI_ROOT}/etc/hosts"

# enable IP forwarding and non-local binding
echo "Enabling IP forwarding & non-local binding"
sed -ie 's/#*net\.ipv4\.ip_forward\s*=\s*[0-9]*/net.ipv4.ip_forward=1\nnet.ipv4.ip_nonlocal_bind=1/' "${PI_ROOT}/etc/sysctl.conf"

# generate keys
SSH_KEY_FILE="${WORK_DIRECTORY}/id_rsa"
SSH_PUB_KEY_FILE="${SSH_KEY_FILE}.pub"
if [[ ! -f "${SSH_KEY_FILE}" ]] || [[ ! -f "${SSH_PUB_KEY_FILE}" ]]; then 
    echo "Generating SSH keys"
    ssh-keygen -N '' -f "${SSH_KEY_FILE}" -t rsa -b 4096 > /dev/null
fi
# add keys to Raspberry Pi
echo "Updating SSH keys"
SSH_DIR="${PI_ROOT}/home/ubuntu/.ssh"
mkdir -p "${SSH_DIR}"
cp "${SSH_KEY_FILE}" "${SSH_PUB_KEY_FILE}" "${SSH_DIR}"
cat "${SSH_PUB_KEY_FILE}" >> "${SSH_DIR}/authorized_keys"
# add custom key
if [[ "${PUB_KEY}" != "" ]]; then
    echo "Adding ${PUB_KEY} to authorized keys"
    cat "${PUB_KEY}" >> "${SSH_DIR}/authorized_keys"
fi
# cleanup keys
echo "Updating authorized keys (SSH)"
cat "${SSH_DIR}/authorized_keys" | sort | uniq > "${SSH_DIR}/authorized_keys.tmp"
mv "${SSH_DIR}/authorized_keys.tmp" "${SSH_DIR}/authorized_keys"
# disable password login
echo "Disabling password authentication (SSH)"
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' "${PI_ROOT}/etc/ssh/sshd_config"
# enable ssh
echo "Enabling SSH"
touch "${PI_BOOT}/ssh"

# enapblu cgroups
echo "Enabling cgroup modules"
cp "${PI_BOOT}/nobtcmd.txt" "${PI_BOOT}/nobtcmd.txt.backup"
echo "$(cat "${PI_BOOT}/nobtcmd.txt.backup") cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1" | xargs > "${PI_BOOT}/nobtcmd.txt"
# disable password expiration
echo "Disabling password expiration"
sed -i 's/expire: true/expire: false/' "${PI_BOOT}/user-data"

# set GPU memory
PI_BOOT_CONFIG="${PI_BOOT}/config.txt"
if [[ "${GPU_MEMORY}" != "" ]]; then
    echo "Setting GPU memory to ${GPU_MEMORY} MB"
    grep -E "^gpu_mem=.*" "${PI_BOOT_CONFIG}" > /dev/null \
        && sed -i -e 's/^gpu_memory=.*/gpu_memory='"${GPU_MEMORY}"'/' "${PI_BOOT_CONFIG}" \
        || echo "gpu_mem=${GPU_MEMORY}" >> "${PI_BOOT_CONFIG}"
fi

# add K8s install scripts
echo "Adding directory with K8s installation scripts"
cp -r "${K8S_INSTALL}" "${PI_ROOT}/home/ubuntu/"

# add examples
MASTER_NODE=$(grep -Ei 'master\s*$' "${CLUSTER_HOSTS_FILE}" | head -1 | awk '{print $2}')
if [[ -d "${EXAMPLES}" ]] && [[ "${MASTER_NODE}" == "${NODE}" ]]; then
    echo "Adding directory with K8s deployment examples"
    cp -r "${EXAMPLES}" "${PI_ROOT}/home/ubuntu/"
fi

# setup http proxy
if [[ "${HTTP_PROXY}" != "" ]]; then
    echo "Setting up proxy (${HTTP_PROXY})"
    NO_PROXY=$(echo "127.0.0.1,localhost,$(cat "${CLUSTER_HOSTS_FILE}"  | grep -vE '\s*#.*' | awk '{print $1}' | xargs | tr " " ",")")
    # system proxy
    cat << EOL > "${PI_ROOT}/etc/environment"
export HTTP_PROXY="${HTTP_PROXY}"
export HTTPS_PROXY="${HTTP_PROXY}"
export NO_PROXY="${NO_PROXY}"
export http_proxy="${HTTP_PROXY}"
export https_proxy="${HTTP_PROXY}"
export no_proxy="${NO_PROXY}"
EOL
    # docker proxy
    mkdir -p "${PI_ROOT}/etc/systemd/system/docker.service.d"
    cat << EOL > "${PI_ROOT}/etc/systemd/system/docker.service.d/http-proxy.conf"
[Service]
Environment=’HTTP_PROXY=${HTTP_PROXY}’
Environment='HTTPS_PROXY=${HTTP_PROXY}'
Environment=’${NO_PROXY}’
EOL
fi

# sync
sync

# set home dir permissions (yep, ubuntu user has UID=1000)
echo "Setting file permissions"
chown -R 1000:1000 "${PI_ROOT}/home/ubuntu/"

# unmount Raspberry Pi storage
echo "Unmounting ${DEVICE}"
umount "${PI_BOOT}"
umount "${PI_ROOT}"

# sync (double tap)
sync

echo "Done!"
