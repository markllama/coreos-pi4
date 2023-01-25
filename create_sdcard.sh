#!/bin/bash

OPTSPEC="c:d:D:n:"

: ${DEFAULT_CONFIG_FILE=config.yaml}
: ${DEFAULT_DATA_DIR=./data}
: ${DEFAULT_IMAGE_DIR=./images}

: ${BUTANE_TEMPLATE=templates/config.bu.j2}
: ${NMCONNECTION_TEMPLATE=templates/device.nmconnection.j2}

: ${FIRMWARE_VERSION=v1.33}  # use latest one from https://github.com/pftf/RPi4/releases
: ${FIRMWARE_ZIPFILE=RPi4_UEFI_Firmware_${FIRMWARE_VERSION}.zip}
: ${FIRMWARE_URL=https://github.com/pftf/RPi4/releases/download/${FIRMWARE_VERSION}/${FIRMWARE_ZIPFILE}}

: ${COREOS_INSTALLER=${HOME}/bin/coreos-installer}

function main() {

    echo "starting"

    parse_arguments $*
    
    : ${CONFIG_FILE=${DEFAULT_CONFIG_FILE}}
    : ${DATA_DIR=${DEFAULT_DATA_DIR}}
    : ${IMAGE_DIR=${DEFAULT_IMAGE_DIR}}
    
    check_requirements

    # Get node number from hostname
    local NODE_NUMBER=$(node_index ${NODE_HOSTNAME})
    
    # Only generate configs for Raspberry Pi 4
    [ ! $(node_architecture ${NODE_NUMBER}) == "aarch64" ] &&
        echo "Node ${NODE_HOSTNAME} is not a raspberry pi: $(node_architecture ${NODE_NUMBER})" &&
        exit 1
        
    generate_config_files ${NODE_NUMBER}
    download_stock_image ${IMAGE_DIR}
    create_sd_card ${BLOCK_DEVICE} ${DATA_DIR}/${NODE_HOSTNAME}
}

function parse_arguments() {
    while getopts "${OPTSPEC}" OPT ; do
        case ${OPT} in
            c)
                CONFIG_FILE=${OPTARG}
                ;;

            d)
                DATA_DIR=${OPTARG}
                ;;

            i)
                IMAGE_DIR=${OPTARG}
                ;;
            
            n)
                NODE_HOSTNAME=${OPTARG}
                ;;

            D)
                BLOCK_DEVICE=${OPTARG}
                ;;

            *)
                echo "FATAL: unprocessed option - $OPT"
                exit 1
                ;;
        esac
    done

    if [ "${NODE_HOSTNAME}x" == "x" ] ; then
        echo "Missing required argument: -n <NODE_HOSTNAME>"
        exit 1
    fi

    if [ "${BLOCK_DEVICE}x" == "x" ] ; then
        echo "Missing required argument: -D <BLOCK_DEVICE>"
        exit 1
    fi
    
}

function check_requirements() {
    local errors=0
    local BINARY
    for BINARY in ${RPM_REQUIREMENTS[@]} ; do
        ! which $BINARY >/dev/null 2>&1 &&
            echo ERROR: missing tool ${BINARY} &&
            errors=$((errors + 1))
    done

    for BINARY in ${PYTHON_REQUIREMENTS[@]} ; do
        ! which $BINARY >/dev/null 2>&1 &&
            echo ERROR: missing tool ${BINARY} &&
            errors=$((errors + 1))
    done

    [ ! -f ${CONFIG_FILE} ] &&
        echo ERROR: Missing config file ${CONFIG_FILE} &&
        errors=$((errors +1))
    
    [ ! -d ${COREOS_DIR} ] &&
        echo ERROR: missing CoreOS pxe image directory &&
        errors=$((errors + 1))

    if [ "${HOSTNAME}x" == 'x' ] ; then
        echo ERROR: Missing required hostname for boot image
        errors=$((errors + 1))
    fi

    [ $errors -ne 0 ] && echo "FATAL: There are ${errors} missing requirements" && exit 1
}

function num_nodes() {
    yq  '.nodes | length' < ${CONFIG_FILE}
}

function seq_nodes() {
    seq 0 $(($(num_nodes) - 1))
}

function node_index() {
    local NODE_HOSTNAME=$1
    yq ".nodes | map(.hostname == \"${NODE_HOSTNAME}\") | index(true)" ${CONFIG_FILE}
}

function node_hostname() {
    local NODE_NUMBER=$1
    yq --raw-output ".nodes[${NODE_NUMBER}].hostname" < ${CONFIG_FILE}
}

function node_architecture() {
    local NODE_NUMBER=$1
    yq --raw-output ".nodes[${NODE_NUMBER}].arch" ${CONFIG_FILE}
}

function node_pxe() {
    local NODE_NUMBER=$1
    local PROV_NIC=$(yq --raw-output ".nodes[${NODE_NUMBER}] | .provisioning_nic" ${CONFIG_FILE})
    [ ${PROV_NIC} != "null" ]
}

function node_nics() {
    local NODE_NUMBER=$1
    yq --raw-output ".nodes[${NODE_NUMBER}].nics | length" ${CONFIG_FILE}
}

function nic_name() {
    local NODE_NUMBER=$1
    local NIC_NUMBER=$2

    yq --raw-output ".nodes[${NODE_NUMBER}].nics[${NIC_NUMBER}].name" ${CONFIG_FILE}
}

function download_stock_image() {
    local IMAGE_DIR=$1

    mkdir -p ${IMAGE_DIR}
    ${COREOS_INSTALLER} download \
                     --stream stable \
                     --architecture aarch64 \
                     --platform metal \
                     --format raw.xz \
                     --directory ${IMAGE_DIR}
}

function image_filename() {
    local IMAGE_DIR=$1
    ls ${IMAGE_DIR}/fedora-coreos-*-metal.aarch64.raw.xz | head -1
}

function generate_config_files() {
    local NODE_NUMBER=$1

    echo Generating configs for node ${NODE_NUMBER}

    local NODENAME=$(node_hostname ${NODE_NUMBER})
    local NODE_CONFIG_DIR=${DATA_DIR}/${NODENAME}
    local IGNITION_FILE=${NODE_CONFIG_DIR}/config.ign
    local NM_FILE
    
    # generate ignition file
    mkdir -p ${NODE_CONFIG_DIR}
    generate_ignition ${NODE_NUMBER} ${IGNITION_FILE}
    
    # generate NetworkManger files
    for NIC_NUMBER in $(seq 0 $(($(node_nics ${NODE_NUMBER}) - 1))) ; do
        echo "NIC: $(nic_name ${NODE_NUMBER} ${NIC_NUMBER})"
        NM_FILE=${NODE_CONFIG_DIR}/$(nic_name ${NODE_NUMBER} ${NIC_NUMBER}).nmconnection
        generate_nmconnection ${NODE_NUMBER} ${NIC_NUMBER} ${NM_FILE}
    done
}

function transform_butane() {
    local NODE_NUMBER=$1

    jinja2 ${BUTANE_TEMPLATE} ${CONFIG_FILE} -D node_number=${NODE_NUMBER} 
}

function transform_nmconnection() {
    local NODE_NUMBER=$1
    local NIC_NUMBER=$2
    jinja2 ${NMCONNECTION_TEMPLATE} ${CONFIG_FILE} -D node_number=${NODE_NUMBER} -D nic_number=${NIC_NUMBER}
}

function generate_ignition() {
    local NODE_INDEX=$1
    local IGNITION_FILE=$2
    BUTANE_FILE=$(mktemp /tmp/fcos-config-XXXX.bu)
    transform_butane ${NODE_INDEX} > ${BUTANE_FILE}
    podman run --interactive --rm \
           --security-opt label=disable \
           --volume ${PWD}:/pwd \
           --workdir /pwd \
           quay.io/coreos/butane:release \
           --pretty --strict \
           <${BUTANE_FILE} >${IGNITION_FILE}
    rm ${BUTANE_FILE}
}

function generate_nmconnection() {
    local NODE_INDEX=$1
    local NIC_INDEX=$2
    local NMCONNECTION_FILE=$3
    transform_nmconnection ${NODE_INDEX} ${NIC_INDEX} >${NMCONNECTION_FILE}
}


function create_sd_card() {
    local BLOCK_DEVICE=$1
    local NODE_CONFIG_DIR=$2
    #
    unmount_filesystems ${BLOCK_DEVICE}
    install_coreos_to_usb ${BLOCK_DEVICE} ${NODE_CONFIG_DIR}/config.ign ${NODE_CONFIG_DIR}
    sleep 2
    local EFI_PARTITION=$(get_EFI_partition ${BLOCK_DEVICE})
    overlay_UEFI_Firmware ${EFI_PARTITION}
}

function unmount_filesystems() {
    local DEVICE=$1
    local PARTITIONS=($(mount | grep "^${DEVICE}" | cut -d' ' -f3))
    local PROCEED
    
    for MOUNTPOINT in ${PARTITIONS[@]} ; do
        ! grep -q -e "^/run/media/${USER}" <((echo ${MOUNTPOINT})) &&
            echo "FATAL: device not mounted in user space: ${MOUNTPOINT}" && exit 3
        echo "INFO: unmounting $(mount | grep ${MOUNTPOINT} | cut -d' ' -f1) [${MOUNTPOINT}]"
        read -p 'Proceed? [y/N]: ' PROCEED
        [ "${PROCEED}x" != 'yx' ] && echo "FATAL: not unmounting ${MOUNTPOINT}" && exit 4
        sudo umount ${MOUNTPOINT}
    done
}

function install_coreos_to_usb() {
    local DEVICE=$1
    local CONFIG=$2
    local NETDIR=$3
    chmod 600 ${NETDIR}/*
    sudo ${COREOS_INSTALLER} install \
         --architecture aarch64 \
         --image-file $(image_filename ${IMAGE_DIR}) \
         --copy-network \
         --network-dir ${NETDIR} \
         --console ttyS0,115200 \
         --ignition-file ${CONFIG} \
         ${DEVICE}
}

function get_EFI_partition() {
    local DEVICE=$1
    lsblk ${DEVICE} -J -oLABEL,PATH  |
        jq -r '.blockdevices[] | select(.label == "EFI-SYSTEM")'.path
}

function overlay_UEFI_Firmware() {
    local EFI_PARTITION=$1
    
    local TMPDIR=$(mktemp --directory /tmp/fcos-rpi-efi-XXXX)
    sudo mount ${EFI_PARTITION} ${TMPDIR}
    sudo curl -L -o /tmp/${FIRMWARE_ZIPFILE} ${FIRMWARE_URL}
    sudo unzip /tmp/${FIRMWARE_ZIPFILE} -d ${TMPDIR}
    sudo rm /tmp/${FIRMWARE_ZIPFILE}
    sudo umount ${TMPDIR}
    sudo rm -rf ${TMPDIR}
    sync
}

function overload_UBoot_Firmware() {
    local EFI_PARTITION=$1

    local MIRROR_URL='https://mirrors.fedoraproject.org/metalink?repo=fedora-$releasever&arch=$basearch'
    local arch="aarch64"
    local releasever="37"
    local mirror_url="http://mirror.fcix.net/fedora/linux/development/$releasever/Everything/${arch}/os/"
    local UBOOT_PACKAGES="uboot-images-armv8 bcm283x-firmware bcm283x-overlays"
    
    # mkdir -p /tmp/RPi4boot/boot/efi/
    # sudo dnf install -y --downloadonly --release=$RELEASE --forcearch=aarch64 \
    # --destdir=/tmp/RPi4boot/ ${UBOOT_PACKAGES}

    local TMPDIR=$(mktemp --directory /tmp/fcos-rpi-efi-XXXX)
    sudo mount ${EFI_PARTITION} ${TMPDIR}
    
}
#
#
#
main $*
