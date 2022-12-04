#!/bin/bash

#
# Fastswap
# 

# Defaults
SCRIPT_DIR=`dirname "$0"`
HOST_SSH="sc40"
HOST_IP="192.168.0.40"
MEMSERVER_SSH="sc07"
MEMSERVER_IP="192.168.0.7"
MEMSERVER_PORT="50000"
FSBACKEND=local

loaded() {
    MODULE=$1
    lsmod | grep -Eq "^$MODULE "
    return $?
}

# parse cli
for i in "$@"
do
case $i in
    -ms=*|--memserver-ssh=*)
    MEMSERVER_SSH="${i#*=}"
    ;;

    -mip=*|--memserver-ip=*)
    MEMSERVER_IP="${i#*=}"
    ;;

    -mp=*|--memserver-port=*)
    MEMSERVER_PORT="${i#*=}"
    ;;
    
    -hs=*|--host-ssh=*)
    HOST_SSH="${i#*=}"
    ;;

    -hip=*|--host-ip=*)
    HOST_IP="${i#*=}"
    ;;
    
    -bk=*|--backend=*)
    FSBACKEND="${i#*=}"
    ;;

    -d|--debug)
    CFLAGS="$CFLAGS -DDEBUG"
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



pushd ${SCRIPT_DIR}/drivers
make clean
if [ "$FSBACKEND" == "rdma" ]; then
    make BACKEND=RDMA
    bkend_sfx=rdma
    bkend_args="sport=${MEMSERVER_PORT} sip=${MEMSERVER_IP} cip=${HOST_IP}"
    bkend_text="ctrl"
elif [ "$FSBACKEND" == "local" ]; then  
    make BACKEND=DRAM
    bkend_sfx=dram
    bkend_args=
    bkend_text="DRAM backend"
else
    echo "Unknown backend $FSBACKEND. Allowed: rdma, local"
    exit 1
fi
popd

# setup memory server
if [ "$FSBACKEND" == "rdma" ]; then
    pushd ${SCRIPT_DIR}/farmemserver
    make clean
    make
    popd

    # re-run memory server
    echo "starting memserver"
    ssh ${MEMSERVER_SSH} "pkill rmserver" || true
    sleep 5     #to unbind port
    ssh ${MEMSERVER_SSH} "mkdir -p ~/scratch"
    scp ${SCRIPT_DIR}/farmemserver/rmserver ${MEMSERVER_SSH}:~/scratch
    ssh ${MEMSERVER_SSH} "nohup ~/scratch/rmserver ${MEMSERVER_PORT} &" < /dev/null &
    sleep 1
fi

# reload client drivers
echo "reloading drivers"
pushd ${SCRIPT_DIR}/drivers
if loaded "fastswap"; then 
    sudo rmmod fastswap
fi
if loaded "fastswap_rdma"; then
    sudo rmmod fastswap_rdma
fi
if loaded "fastswap_dram"; then
    sudo rmmod fastswap_dram
fi

prevsuccess=$(sudo dmesg | grep "${bkend_text} is ready for reqs" | wc -l)
echo sudo insmod fastswap_${bkend_sfx}.ko ${bkend_args} 
sudo insmod fastswap_${bkend_sfx}.ko ${bkend_args} 
currsuccess=$(sudo dmesg | grep "${bkend_text} is ready for reqs" | wc -l)
if [ $currsuccess -le $prevsuccess ]; then 
    echo "load failed";
    exit 1 
fi
# sudo dmesg 
sudo insmod fastswap.ko
popd

# setup cgroups
pushd ${SCRIPT_DIR}
sudo mkdir -p /cgroup2
./init_bench_cgroups.sh
popd