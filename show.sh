#!/bin/bash
# set -e
#
# Show info on past (good) runs
# For previous data, activate "data" repo in git submodules (.gitmodules)
#

usage="\n
-s, --suffix \t\t a plain suffix defining the set of runs to show\n
-cs, --csuffix \t same as suffix but a more complex one (with regexp pattern)\n
-t, --threads \t\t results filter: == threads\n
-c, --cores \t\t results filter: == cores\n
-d, --desc \t\t results filter: contains desc\n
-lm, --lmem \t\t results filter: == localmem\n
-of, --outfile \t output results to a file instead of stdout\n"

HOST="sc2-hs2-b1630"
CLIENT="sc2-hs2-b1632"

# Read parameters
for i in "$@"
do
case $i in
    -s=*|--suffix=*)
    SUFFIX="${i#*=}"
    ;;

    -cs=*|--csuffix=*)
    CSUFFIX="${i#*=}"
    ;;
    
    -of=*|--outfile=*)
    OUTFILE="${i#*=}"
    ;;

    # OUTPUT FILTERS
    -c=*|--cores=*)
    CORES="${i#*=}"
    ;;

    -t=*|--threads=*)
    THREADS="${i#*=}"
    ;;

    -lm=*|--lmem=*)
    LOCALMEM="${i#*=}"
    ;;

    -d=*|--desc=*)
    DESC="${i#*=}"
    ;;

    -*|--*)     # unknown option
    echo "Unknown Option: $i"
    echo -e $usage
    exit
    ;;

    *)          # take any other option as simple suffix     
    SUFFIX="${i}"
    ;;

esac
done

if [[ $SUFFIX ]]; then 
    LS_CMD=`ls -d1 data/run-${SUFFIX}*/`
    SUFFIX=$SUFFIX
elif [[ $CSUFFIX ]]; then
    LS_CMD=`ls -d1 data/*/ | grep -e "$CSUFFIX"`
    SUFFIX=$CSUFFIX
else 
    SUFFIX=$(date +"%m-%d")     # default to today
    LS_CMD=`ls -d1 data/run-${SUFFIX}*/`
fi
# echo $LS_CMD

for exp in $LS_CMD; do
    # config
    # echo $exp
    name=$(basename $exp)
    readme=$(cat $exp/readme 2>/dev/null)
    cores=$(cat $exp/cores 2>/dev/null)
    threads=$(cat $exp/threads 2>/dev/null)
    lmem=$(cat $exp/localmem 2>/dev/null)
    initmem=$(cat $exp/initial_memory 2>/dev/null | grep total | awk '{ print $2 }' | sed 's/K//g')
    peakmem=$(cat $exp/peak_memory 2>/dev/null | grep total | awk '{ print $2 }' | sed 's/K//g')
    datamem=$((peakmem-initmem))

    # apply filters
    if [[ $THREADS ]] && [ "$THREADS" != "$threads" ];  then    continue;   fi
    if [[ $CORES ]] && [ "$CORES" != "$cores" ];        then    continue;   fi
    if [[ $LOCALMEM ]] && [ "$LOCALMEM" != "$lmem" ];   then    continue;   fi
    if [[ $DESC ]] && [[ "$readme" != *"$DESC"*  ]];    then    continue;   fi
    
    # xput
    preload_start=$(cat $exp/preload_start 2>/dev/null)
    preload_end=$(cat $exp/preload_end 2>/dev/null)
    ptime=$((preload_end-preload_start))
    pxput=$(cat $exp/preload_out 2>/dev/null | grep TPS | awk '{ print $7 }')

    sample_start=$(cat $exp/sample_start 2>/dev/null)
    sample_end=$(cat $exp/sample_end 2>/dev/null)
    stime=$((sample_end-sample_start))
    sxput=$(cat $exp/sample_out 2>/dev/null | grep TPS | awk '{ print $7 }')

    # other stats
    rss=$(cat $exp/memcached_out 2>/dev/null | grep "Maximum resident set size" | awk -F: '{ print $2 }' | xargs)
    pgfmajor=$(cat $exp/memcached_out 2>/dev/null | grep "Major .* page faults" | awk -F: '{ print $2 }' | xargs)
    pgfminor=$(cat $exp/memcached_out 2>/dev/null | grep "Minor .* page faults" | awk -F: '{ print $2 }' | xargs)
    cpuper=$(cat $exp/memcached_out 2>/dev/null | grep "Percent of CPU" | awk -F: '{ print $2 }' | xargs)
    pgfminor=$(cat $exp/memcached_out 2>/dev/null | grep "Minor .* page faults" | awk -F: '{ print $2 }' | xargs)

    # pgfaults - specific
    pgfile=$exp/sar_pgfaults_majflts
    if [ ! -f $pgfile ]; then bash parse_sar.sh -n=${name} -sf=pgfaults -sc=majflt/s -t1=$sample_start -t2=$sample_end -of=$pgfile; fi
    majpgfrate=$(tail -n+2 $pgfile 2>/dev/null | awk '{ s+=$1 } END { if (NR > 0) printf "%d", (s/NR) }')

    pgfile=$exp/sar_pgfaults_allflts
    if [ ! -f $pgfile ]; then bash parse_sar.sh -n=${name} -sf=pgfaults -sc=fault/s -t1=$sample_start -t2=$sample_end -of=$pgfile; fi
    allpgfrate=$(tail -n+2 $pgfile 2>/dev/null | awk '{ s+=$1 } END { if (NR > 0) printf "%d", s/NR }')
    minpgfrate=$((allpgfrate-majpgfrate))

    # # pgfaults - from memory.stat
    pgfbefore=$(cat $exp/mem_stat_before 2>/dev/null | grep "pgmajfault" | awk '{ print $2 }')
    pgfafter=$(cat $exp/mem_stat_after 2>/dev/null | grep "pgmajfault" | awk '{ print $2 }')
    majpgfrate2=$(echo $pgfafter $pgfbefore $stime | awk '{ if ($3) printf("%d", ($1-$2)/$3) }')
    pgfbefore=$(cat $exp/mem_stat_before 2>/dev/null | grep "pgfault" | awk '{ print $2 }')
    pgfafter=$(cat $exp/mem_stat_after 2>/dev/null | grep "pgfault" | awk '{ print $2 }')
    allpgfrate2=$(echo $pgfafter $pgfbefore $stime | awk '{ if ($3) printf("%d", ($1-$2)/$3) }')
    minpgfrate2=$((allpgfrate2-majpgfrate2))

    # gather values
    HEADER="Exp";                   LINE="$name";
    HEADER="$HEADER,CPU";           LINE="$LINE,${cores:--}";
    HEADER="$HEADER,Threads";       LINE="$LINE,${threads:--}";
    HEADER="$HEADER,DataMem";       LINE="$LINE,${datamem:--}";
    HEADER="$HEADER,PeakMem";       LINE="$LINE,${peakmem:--}";
    HEADER="$HEADER,LocalMem";      LINE="$LINE,${lmem:--}";
    HEADER="$HEADER,PreloadRate";   LINE="$LINE,${pxput:--}";
    HEADER="$HEADER,PreloadTime";   LINE="$LINE,${ptime:--}";
    HEADER="$HEADER,Runtime";       LINE="$LINE,${stime:--}";
    HEADER="$HEADER,Xput";          LINE="$LINE,${sxput:--}";
    HEADER="$HEADER,RSS_KB";        LINE="$LINE,${rss:--}";
    HEADER="$HEADER,MajPGF";        LINE="$LINE,${pgfmajor:--}";
    HEADER="$HEADER,MinPGF";        LINE="$LINE,${pgfminor:--}";
    HEADER="$HEADER,MajPGF/s";      LINE="$LINE,${majpgfrate:--}";
    HEADER="$HEADER,MinPGF/s";      LINE="$LINE,${minpgfrate:--}";
    HEADER="$HEADER,MajPGF2/s";     LINE="$LINE,${majpgfrate2:--}";
    HEADER="$HEADER,MinPGF2/s";     LINE="$LINE,${minpgfrate2:--}";
    HEADER="$HEADER,CPU%";          LINE="$LINE,${cpuper:--}";
    # HEADER="$HEADER,Desc";          LINE="$LINE,${readme:0:20}";    
    OUT=`echo -e "${OUT}\n${LINE}"`
done

if [[ $OUTFILE ]]; then 
    echo "${HEADER}${OUT}" > $OUTFILE
    echo "wrote results to $OUTFILE"
else
    echo "${HEADER}${OUT}" | column -s, -t
fi