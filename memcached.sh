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
SCRIPT_DIR=`dirname "$0"`
FASTSWAP_DIR=${SCRIPT_DIR}
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
    bash ${FASTSWAP_DIR}/setup.sh           \
        --memserver-ssh=${MEMSERVER_SSH}    \
        --memserver-ip=${MEMSERVER_IP}      \
        --memserver-port=${MEMSERVER_PORT}  \
        --host-ip=${HOST_IP}                \
        --host-ssh=${HOST_SSH}

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

# # run app
# set local memory
mkdir -p /cgroup2/benchmarks/memcached/
LOCALMEM=${LOCALMEM:-max}
echo ${LOCALMEM} > /cgroup2/benchmarks/memcached/memory.high
echo "$LOCALMEM" > $expdir/localmem

# start memcached in a separate process
start_sar 1 ${expdir}
pidfile=${TMPFILE_PFX}mcached_pid
nohup sudo taskset -a -c ${CPUSTR} /usr/bin/time -v ${SCRIPT_DIR}/../memcached/memcached    \
    -u ayelam -r -l localhost -U ${MEMCACHED_PORT} -p ${MEMCACHED_PORT}                     \
    -c ${MAXCONNS} -b 32768 -m 32000 -t ${NTHREADS} -P ${pidfile} -v 2>&1                   \
    -o hashpower=28,no_hashexpand,no_lru_crawler,no_lru_maintainer,idle_timeout=0 | tee ${expdir}/memcached_out &
# -o hashpower=28,no_hashexpand,lru_crawler,lru_maintainer,idle_timeout=0 
sleep 2
pid=$(cat $pidfile)
echo $pid > /cgroup2/benchmarks/memcached/cgroup.procs
sudo pmap $pid > ${expdir}/initial_memory

# memaslap key-value settings
kv_cfg="""generated keys
key
${KEY_SIZE} ${KEY_SIZE} 1
total generated values
value
${VALUE_SIZE} ${VALUE_SIZE} 1"""

# preload
CLIENT_THR=8        #FIXME: only CLIENT_THR <= 10
CONCUR_PER_THR=128
NCONCUR=$((CLIENT_THR*CONCUR_PER_THR))  # SHOULD BE < MAXCONNS
WIN_SIZE_K=10
WIN_SIZE=$((WIN_SIZE_K*1024))
echo $NKEYS, $((NCONCUR*WIN_SIZE))
if [ $NKEYS -ne $((NCONCUR*WIN_SIZE)) ]; then 
    echo "concur * window size must be equal to the number of keys for preload"
    exit 1
fi
preload_cfg="""
cmd
0 1"""          # all SET for preload
echo "$kv_cfg" "$preload_cfg" > ${TMPFILE_PFX}memslap_preload
echo `date +%s` > ${expdir}/preload_start
CPUSTR="0-$((0+CLIENT_THR-1))"      #FIXME: only CLIENT_THR <= 10
nohup taskset -a -c ${CPUSTR} memaslap -s localhost:${MEMCACHED_PORT}     \
    -F ${TMPFILE_PFX}memslap_preload                                \
    -T ${CLIENT_THR} -c ${NCONCUR} -x ${NKEYS} -w "${WIN_SIZE_K}k" | tee ${expdir}/preload_out
echo `date +%s` > ${expdir}/preload_end
sudo pmap $pid > ${expdir}/peak_memory
cat /cgroup2/benchmarks/memcached/memory.stat > ${expdir}/mem_stat_before

# wait some time for preload to settle
sleep 5

# access (actual run)
access_cfg="""
cmd
0 0.002
1 0.998"""     # 99.8% GET
echo "$kv_cfg" "$access_cfg" > ${TMPFILE_PFX}memslap_access
echo `date +%s` > ${expdir}/sample_start
CPUSTR="0-$((0+CLIENT_THR-1))"      #FIXME: only CLIENT_THR <= 10
nohup taskset -a -c ${CPUSTR} memaslap -s localhost:${MEMCACHED_PORT}             \
    -F ${TMPFILE_PFX}memslap_access --warmedup -T ${CLIENT_THR} ${UDPFLAG}  \
    -c ${NCONCUR} -w "${WIN_SIZE_K}k" -t "${RUNTIME_SECS}s" | tee ${expdir}/sample_out
echo `date +%s` > ${expdir}/sample_end
cat /cgroup2/benchmarks/memcached/memory.stat > ${expdir}/mem_stat_after
# TODO make sure get_misses is 0

# all good, save the run
mv ${expdir} $DATADIR/

cleanup