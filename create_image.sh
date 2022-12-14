#!/bin/bash

OPTSPEC="c:d:i:"

: ${DEFAULT_CONFIG_FILE=config.yaml}
: ${DEFAULT_DATA_DIR=./data}

: ${BUTANE_TEMPLATE=templates/config.bu.j2}
: ${NMCONNECTION_TEMPLATE=templates/device.nmconnection.j2}

function main() {

    echo "starting"

    parse_arguments $*
    
    : ${CONFIG_FILE=${DEFAULT_CONFIG_FILE}}
    : ${DATA_DIR=${DEFAULT_DATA_DIR}}

    check_requirements

#    download_stock_image ${IMAGE_DIR}

    # Get node number from hostname
    local NODE_NUMBER=$(node_index ${NODE_HOSTNAME})

    
    # Only generate configs for Raspberry Pi 4
    [ $(node_architecture ${NODE_NUMBER}) == "aarch64" ] || continue
        
    generate_config_files ${NODE_NUMBER}
    #create_image ${NODE_NUMBER}
        
    done
}

function parse_arguments() {
    while getopts ${OPTSPEC} OPT ; do
        case ${OPT} in
            c)
                CONFIG_FILE=${OPTARG}
                ;;

            d)
                DATA_DIR=${OPTARG}
                ;;
            
            n)
                HOSTNAME=${OPTARG}
                ;;
            *)
                echo FATAL: unprocessed option - "$OPT"
                exit 1
                ;;
        esac

    done

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

    coreos-installer download \
                     --stream stable \
                     --architecture aarch64 \
                     --platform metal \
                     --format iso \
                     --directory ${IMAGE_DIR}
}

function image_filename() {
    ls ${IMAGE_DIR}/fedora-coreos-*-live.aarch64.iso | head -1
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

function create_image() {
    local NODE_NUMBER=$1

    local NODE_HOSTNAME=$(node_hostname ${NODE_NUMBER})
    local IGNITION_FILE=${DATA_DIR}/${NODE_HOSTNAME}/config.ign
    local NM_CONFIG_FILE=${DATA_DIR}/${NODE_HOSTNAME}/*.nmconnection
    local INPUT_IMAGE=$(image_filename)
    local OUTPUT_IMAGE=${IMAGE_DIR}/$(node_hostname ${NODE_NUMBER}).iso

    
    echo Creating image for node ${NODE_HOSTNAME}

    # Remove old images before replacing them
    [ -f ${OUTPUT_IMAGE} ] && rm -f ${OUTPUT_IMAGE}
    
    coreos-installer iso customize \
                     --dest-ignition ${IGNITION_FILE} \
                     --network-keyfile ${NM_CONFIG_FILE} \
                     --output  ${OUTPUT_IMAGE} \
                     ${INPUT_IMAGE}
      
    # Add ignition file

    # add nic files
}

function create_sd_card() {
    #
    #
    #
    
}
#
#
#
main $*
