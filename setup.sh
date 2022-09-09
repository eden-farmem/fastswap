#!/bin/bash

#
# Fastswap
# 

# Defaults
SCRIPT_DIR=`dirname "$0"`
HOST_SSH="sc40"
HOST_IP="192.168.0.40"
MEMSERVER_SSH="sc32"
MEMSERVER_IP="192.168.0.32"
MEMSERVER_PORT="50000"

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
make BACKEND=RDMA
popd
pushd ${SCRIPT_DIR}/farmemserver
make clean
make
popd

# run memory server
echo "starting memserver"
ssh ${MEMSERVER_SSH} "pkill rmserver" || true
sleep 1     #to unbind port
ssh ${MEMSERVER_SSH} "mkdir -p ~/scratch"
scp ${SCRIPT_DIR}/farmemserver/rmserver ${MEMSERVER_SSH}:~/scratch
ssh ${MEMSERVER_SSH} "~/scratch/rmserver ${MEMSERVER_PORT} | tee -a ~/scratch/out" &
sleep 2

# reload client drivers
echo "loading drivers"
pushd ${SCRIPT_DIR}/drivers
if loaded "fastswap"; then      sudo rmmod fastswap;        fi
if loaded "fastswap_rdma"; then sudo rmmod fastswap_rdma;   fi
prevsuccess=$(sudo dmesg | grep "ctrl is ready for reqs" | wc -l)
sudo insmod fastswap_rdma.ko sport=${MEMSERVER_PORT} sip="${MEMSERVER_IP}" cip="${HOST_IP}" 
currsuccess=$(sudo dmesg | grep "ctrl is ready for reqs" | wc -l)
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