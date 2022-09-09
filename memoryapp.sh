#!/bin/bash

#
# Fastswap
# 

usage="Example: bash run.sh -f\n
-n, --name \t optional exp name (becomes folder name)\n
-d, --readme \t optional exp description\n
-s, --setup \t rebuild and reload fastswap, farmemory server, cgroups, etc\n
-so, --setuponly \t only setup, no run\n
-c, --clean \t run only the cleanup part\n
-t, --thr \t number of kernel threads\n
-c, --cpu \t number of CPU cores\n
-m, --mem \t local memory limit for the app\n
-u, --udp \t run client with UDP\n
-d, --debug \t build debug\n
-d, --gdb \t run with a gdb server (on port :1234) to attach to\n
-h, --help \t this usage information message\n"

#Defaults
APPNAME="memoryapp"
SCRIPT_DIR=`dirname "$0"`
DATADIR="${SCRIPT_DIR}/data/"
HOST_SSH="sc40"
HOST_IP="192.168.0.40"
MEMSERVER_SSH="sc32"
MEMSERVER_IP="192.168.0.32"
MEMSERVER_PORT="50000"
MEMCACHED_PORT="11211"
FASTSWAP_RECLAIM_CPU=54     # avoid scheduling on this CPU
TMPFILE_PFX="tmp_fswap_"
NTHREADS=1
NCORES=1
KEY_SIZE=20
VALUE_SIZE=80
NKEYS=$((10*1024*1024))             # 10m
EXPNAME=run-$(date '+%m-%d-%H-%M');     # unique id
MAXCONNS=32768 
RUNTIME_SECS=30

# parse cli
for i in "$@"
do
case $i in
    -n=*|--name=*)
    EXPNAME="${i#*=}"
    ;;

    -d=*|--readme=*)
    README="${i#*=}"
    ;;

    -d|--debug)
    CFLAGS="$CFLAGS -DDEBUG"
    ;;

    -s|--setup)
    SETUP=1
    ;;
        
    -so|--setuponly)
    SETUP=1
    SETUP_ONLY=1
    ;;
    
    -c|--clean)
    CLEANUP=1
    ;;

    -g|--gdb)
    GDB=1
    CFLAGS="$CFLAGS -DDEBUG -g -ggdb"
    ;;
    
    -t=*|--thr=*)
    NTHREADS="${i#*=}"
    ;;

    -c=*|--cores=*)
    NCORES="${i#*=}"
    ;;

    -m=*|--mem=*)
    LOCALMEM="${i#*=}"
    ;;

    -u|--udp)
    UDPFLAG="-U"
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

# Initial CPU allocation
# NUMA node0 CPU(s):   0-13,28-41
# NUMA node1 CPU(s):   14-27,42-55
# 14-27 for memcached, 42-53 for memaslap
# RNIC NUMA node = 1
CPUSTR="14-$((14+NCORES-1))"      #FIXME: only NCORES < 14

# helpers
loaded() {
    MODULE=$1
    lsmod | grep -Eq "^$MODULE "
    return $?
}
cleanup() {
    rm -f ${TMPFILE_PFX}*
    pkill memcached
    pkill memslap
    pkill sar
    sleep 1     #for ports to be unbound
}
start_sar() {
    int=$1
    outdir=$2
    nohup sar -r ${int}     | ts %s > ${outdir}/memory.sar  2>&1 &
    nohup sar -b ${int}     | ts %s > ${outdir}/diskio.sar  2>&1 &
    nohup sar -P ALL ${int} | ts %s > ${outdir}/cpu.sar     2>&1 &
    nohup sar -n DEV ${int} | ts %s > ${outdir}/network.sar 2>&1 &
    nohup sar -B ${int}     | ts %s > ${outdir}/pgfaults.sar 2>&1 &
}
stop_sar() {
    pkill sar
}

#start clean  
cleanup 
if [[ $CLEANUP ]]; then exit 0; fi

# build & load fastswap
set -e
if [[ $SETUP ]]; then 
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
    sudo insmod fastswap_rdma.ko sport=$MEMSERVER_PORT sip="$MEMSERVER_IP" cip="$HOST_IP" 
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

    if [[ $SETUP_ONLY ]]; then  exit 0; fi
fi

# initialize run
expdir=$EXPNAME
mkdir -p $expdir
if [[ $README ]]; then
    echo "$README" > $expdir/readme
fi
echo "running ${EXPNAME} with ${NCORES}:${NTHREADS}"
echo "$NCORES" > $expdir/cores
echo "$NTHREADS" > $expdir/threads
echo "$APPNAME" > $expdir/app

# # run app
# set local memory
mkdir -p /cgroup2/benchmarks/$APPNAME/
LOCALMEM=${LOCALMEM:-max}
echo ${LOCALMEM} > /cgroup2/benchmarks/$APPNAME/memory.high
echo "$LOCALMEM" > $expdir/localmem

# start memcached in a separate process
start_sar 1 ${expdir}
pidfile=${TMPFILE_PFX}mcached_pid

CPUSTR="0-$((0+CLIENT_THR-1))"      #FIXME: only CLIENT_THR <= 10
nohup taskset -a -c ${CPUSTR} RUN APP
sleep 2
pid=$(cat $pidfile)
echo $pid > /cgroup2/benchmarks/memcached/cgroup.procs
sudo pmap $pid > ${expdir}/initial_memory

# all good, save the run
mv ${expdir} $DATADIR/

cleanup