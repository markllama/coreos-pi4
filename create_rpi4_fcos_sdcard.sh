#!/bin/bash
#
#
: ${IGNITION_FILE_DIR="configs/ign"}
: ${NM_ROOT="configs/nm"}
: ${FIRMWARE_VERSION=v1.33}  # use latest one from https://github.com/pftf/RPi4/releases
: ${FIRMWARE_ZIPFILE=RPi4_UEFI_Firmware_${FIRMWARE_VERSION}.zip}
: ${FIRMWARE_URL=https://github.com/pftf/RPi4/releases/download/${FIRMWARE_VERSION}/${FIRMWARE_ZIPFILE}}

# DEVICE
# NODENAME

OPTSTRING="d:n:"

function main() {
    parse_opts $*

    local ERRORS=0
    
    local DEVICE_PATH=/dev/${DEVICE}
    [ ! -b ${DEVICE_PATH} ] &&
        echo "ERROR: ${DEVICE_PATH} is not a block device" &&
        ERRORS=$((${ERRORS} + 1))

    local IGNITION_FILE=${IGNITION_FILE_DIR}/${NODENAME}.ign
    [ ! -r ${IGNITION_FILE} ] &&
        echo "ERROR: File Not Found: ${IGNITION_FILE}" &&
        ERRORS=$((${ERRORS} + 1))

    local NM_DIR=${NM_ROOT}/${NODENAME}
    [ ! -d ${NM_DIR} ] &&
        echo "ERROR: Network Directory not found ${NM_DIR}" &&
        ERRORS=$((${ERRORS} + 1))
    
    [ ${ERRORS} -gt 0 ] && echo "FATAL: invalid options" && exit 2

    unmount_filesystems ${DEVICE_PATH}
    install_coreos_to_usb ${DEVICE_PATH} ${IGNITION_FILE} ${NM_DIR}
    sleep 2
    local EFI_PARTITION=$(get_EFI_partition ${DEVICE_PATH})
    overlay_UEFI_Firmware ${EFI_PARTITION}
}

function parse_opts() {

    while getopts "${OPTSTRING}" OPT ; do
        case "$OPT" in
            d)
                DEVICE=${OPTARG}
                ;;
            n)
                NODENAME=${OPTARG}
                ;;
            *)
                echo "Invalid Argument: ${OPT}"
                exit 1
                ;;
        esac
    done

    local ERRORS=0

    [ -z "${DEVICE}" ] &&
        echo "ERROR: Missing required argument -d <device>" &&
        ERRORS=$((${ERRORS} + 1))

    [ -z "${NODENAME}" ] &&
        echo "ERROR: Missing required argument -n <nodename>" &&
        ERRORS=$((${ERRORS} + 1))

    [ "${ERRORS}" -gt 0 ] && echo "FATAL: there are ${ERRORS} missing arguments" && exit 1
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
    sudo coreos-installer install \
         --architecture aarch64 \
         --ignition-file ${CONFIG} \
         --copy-network \
         --network-dir ${NETDIR} \
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

# ------------------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------------------
main $*
