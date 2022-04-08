#!/bin/bash

#
# Test Nadav Amit's prefetch_page() API for Userfaultfd pages using Kona
# Requires this kernel patch/feature: 
# https://lore.kernel.org/lkml/20210225072910.2811795-4-namit@vmware.com/
# 

usage="Example: bash run.sh -f\n
-r, --reload \t rebuild and reload fastswap\n
-c, --clean \t run only the cleanup part\n
-d, --debug \t build debug\n
-d, --gdb \t run with a gdb server (on port :1234) to attach to\n
-h, --help \t this usage information message\n"

#Defaults
SCRIPT_DIR=`dirname "$0"`
DIR="${SCRIPT_DIR}/../fastswap"
HOST_SSH="sc40"
HOST_IP="192.168.0.40"
MEMSERVER_SSH="sc07"
MEMSERVER_IP="192.168.0.7"
MEMSERVER_PORT="50000"

# parse cli
for i in "$@"
do
case $i in
    -d|--debug)
    CFLAGS="$CFLAGS -DDEBUG"
    ;;

    -r|--reload)
    RELOAD=1
    ;;
    
    -c|--clean)
    CLEANUP=1
    ;;

    -g|--gdb)
    GDB=1
    CFLAGS="$CFLAGS -DDEBUG -g -ggdb"
    ;;

    -h | --help)
    echo -e $usage
    exit
    ;;

    *)                      # unknown option
    echo "Unknown Option: $i"
    echo -e $usage
    exit
    ;;
esac
done

# helpers
loaded() {
    MODULE=$1
    lsmod | grep -Eq "^$MODULE "
    return $?
}
cleanup() {
    ssh ${MEMSERVER_SSH} "pkill rmserver; rm -f ~/scratch/rmserver" 
}

#start clean
cleanup     
if [[ $CLEANUP ]]; then
    exit 0
fi

# build & load fastswap
set -e
if [[ $RELOAD ]]; then 
    pushd ${SCRIPT_DIR}/drivers
    make clean
    make BACKEND=RDMA
    popd
    pushd ${SCRIPT_DIR}/farmemserver
    make clean
    make
    popd

    # run memory server
    echo "starting memserver"
    ssh ${MEMSERVER_SSH} "mkdir -p ~/scratch"
    scp ${SCRIPT_DIR}/farmemserver/rmserver ${MEMSERVER_SSH}:~/scratch
    ssh ${MEMSERVER_SSH} "~/scratch/rmserver ${MEMSERVER_PORT} | tee -a ~/scratch/out" &
    sleep 2

    # reload client drivers
    echo "loading drivers"
    pushd ${SCRIPT_DIR}/drivers
    if loaded "fastswap"; then sudo rmmod fastswap_rdma; fi
    if loaded "fastswap_rdma"; then sudo rmmod fastswap_rdma; fi
    prevsuccess=$(sudo dmesg | grep "ctrl is ready for reqs" | wc -l)
    sudo insmod fastswap_rdma.ko sport=$MEMSERVER_PORT sip="$MEMSERVER_IP" cip="$HOST_IP" 
    currsuccess=$(sudo dmesg | grep "ctrl is ready for reqs" | wc -l)
    if [ $currsuccess -le $prevsuccess ]; then 
        echo "load failed";
        exit 1 
    fi
    # sudo dmesg 
    sudo insmod fastswap.ko
    popd
fi

# run app


# cleanup
