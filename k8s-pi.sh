#!/bin/bash -eu

# check root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# variables
BIN=$(basename "${0}" | sed 's/\..*//')
DIR=$(dirname $(readlink -f "${0}"))
K8S_INSTALL="${DIR}/k8s"
RASPBIAN_IMAGE_URL=${RASPBIAN_IMAGE_URL:-"https://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2019-09-30/2019-09-26-raspbian-buster-lite.zip"}
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
    --raspbian-image-url=<value> ... raspbian image URL (default --raspbian-image-url="${RASPBIAN_IMAGE_URL}")
    --work-directory=<value>     ... working directory (default --work-directory="${WORK_DIRECTORY}")
    --add-pub-key=<value>        ... public key to add to authorized_keys
    --gpu-memory=<value>         ... GPU memory to use (values 16, 64, 128, 256, 512)
    --no-cache                   ... force download Raspbian image
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
        --raspbian-image-url=*)
            RASPBIAN_IMAGE_URL="${ARG_VALUE}";;
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
    read -p "Continue and unmount device? [y/N] " -n 1 -r
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
    IMAGE_FILE="$(basename "${RASPBIAN_IMAGE_URL}" "$(basename "${RASPBIAN_IMAGE_URL}" | sed 's/.*\././')").img"
    IMAGE_FULLPATH="${WORK_DIRECTORY}/${IMAGE_FILE}"
    if [[ ! -f "${IMAGE_FULLPATH}" ]] || [[ "${NO_CACHE}" == "true" ]]; then
        IMAGE_ZIP="${WORK_DIRECTORY}/$(basename "${RASPBIAN_IMAGE_URL}")"
        if [[ ! -f "${IMAGE_ZIP}" ]] || [[ "${NO_CACHE}" == "true" ]]; then
            echo "Downloading ${RASPBIAN_IMAGE_URL}"
            wget -q --show-progress "${RASPBIAN_IMAGE_URL}" -O "${IMAGE_ZIP}"
        fi
        echo "Extracting ${IMAGE_FILE}"
        unzip -u -d "${WORK_DIRECTORY}" "${IMAGE_ZIP}" "${IMAGE_FILE}"
    fi
    IMAGE_FILE="${IMAGE_FULLPATH}"
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
    dd if="${IMAGE_FILE}" of="${DEVICE}" bs=1M status=progress
    sync
    # resize partition to max
    parted -s "${DEVICE}" resizepart 2 100%
fi

# mount Raspberry Pi storage
PI_BOOT="${WORK_DIRECTORY}/mnt/boot"
PI_ROOT="${WORK_DIRECTORY}/mnt/root"
mkdir -p "${PI_BOOT}" "${PI_ROOT}"
mount "${DEVICE}p1" "${PI_BOOT}"
mount "${DEVICE}p2" "${PI_ROOT}"

# setup network 
echo "Setting up network (DHCP)"
sed -i 's/raspberrypi/'"${NODE}"'/g' "${PI_ROOT}/etc/hostname" "${PI_ROOT}/etc/hosts"
cat "${CLUSTER_HOSTS_FILE}" | grep -v -E '(^\s*#.*$|^\s*$)' >> "${PI_ROOT}/etc/hosts"

# enable IP forwarding and non-local binding
sed -ie 's/#*net\.ipv4\.ip_forward\s*=\s*[0-9]*/net.ipv4.ip_forward=1\nnet.ipv4.ip_nonlocal_bind=1/' "${PI_ROOT}/etc/sysctl.conf"

# setup SSH
echo "Seting up SSH"
# generate keys
SSH_KEY_FILE="${WORK_DIRECTORY}/id_rsa"
SSH_PUB_KEY_FILE="${SSH_KEY_FILE}.pub"
if [[ ! -f "${SSH_KEY_FILE}" ]] || [[ ! -f "${SSH_PUB_KEY_FILE}" ]]; then 
    echo "Generating SSH keys"
    ssh-keygen -N '' -f "${SSH_KEY_FILE}" -t rsa -b 4096 > /dev/null
fi
# add keys to Raspberry Pi
PI_SSH_DIR="${PI_ROOT}/home/pi/.ssh"
mkdir -p "${PI_SSH_DIR}"
cp "${SSH_KEY_FILE}" "${PI_SSH_DIR}"
cat "${SSH_PUB_KEY_FILE}" >> "${PI_SSH_DIR}/authorized_keys"
# add custom key
if [[ "${PUB_KEY}" != "" ]]; then
    cat "${PUB_KEY}" >> "${PI_SSH_DIR}/authorized_keys"
fi
# cleanup keys
cat "${PI_SSH_DIR}/authorized_keys" | sort | uniq > "${PI_SSH_DIR}/authorized_keys.tmp"
cp "${PI_SSH_DIR}/authorized_keys.tmp" "${PI_SSH_DIR}/authorized_keys"
# disable password login
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' "${PI_ROOT}/etc/ssh/sshd_config"
# enable ssh
touch "${PI_BOOT}/ssh"

# enapblu cgroups
echo "cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1" >> "${PI_BOOT}/cmdline.txt"

# set GPU memory
PI_BOOT_CONFIG="${PI_BOOT}/config.txt"
if [[ "${GPU_MEMORY}" != "" ]]; then
    echo "Setting GPU memory to ${GPU_MEMORY} MB"
    grep -E "^gpu_mem=.*" "${PI_BOOT_CONFIG}" > /dev/null \
        && sed -i -e 's/^gpu_memory=.*/gpu_memory='"${GPU_MEMORY}"'/' "${PI_BOOT_CONFIG}" \
        || echo "gpu_mem=${GPU_MEMORY}" >> "${PI_BOOT_CONFIG}"
fi

# add K8s install scripts
echo "Adding K8s install scripts"
cp -r "${K8S_INSTALL}" "${PI_ROOT}/home/pi/"

# setup http proxy
if [[ "${HTTP_PROXY}" != "" ]]; then
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
sync

# unmount Raspberry Pi storage
umount "${PI_BOOT}"
umount "${PI_ROOT}"

sync
