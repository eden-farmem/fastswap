#!/bin/bash
# set -e

# Fastswap plots

PLOTEXT=png
SCRIPT_DIR=`dirname "$0"`
PLOTDIR=${SCRIPT_DIR}/plots
DATADIR=${SCRIPT_DIR}/data
SHENANGO_DATADIR=${SCRIPT_DIR}/../data
TMP_FILE_PFX=tmp_fastswap_

mean() {
    csvfile=$1
    colid=$2
    tail -n +2 $csvfile | awk -F, '{ sum += $'$colid'; n++ } 
        END { if (n > 0) printf sum / n; }'
}

stdev() {
    csvfile=$1
    colid=$2
    tail -n +2 $csvfile | awk -F, '{ x+=$'$colid'; y+=$'$colid'^2; n++ } 
        END { if (n > 0) print sqrt(y/n-(x/n)^2)}'
}

usage="\n
-f, --force \t\t force re-summarize data and re-generate plots\n
-fp, --force-plots \t force re-generate just the plots\n
-id, --plotid \t pick one of the many charts this script can generate\n
-h, --help \t\t this usage information message\n"

for i in "$@"
do
case $i in
    -f|--force)
    FORCE=1
    FORCE_PLOTS=1
    FORCE_FLAG=" -f "
    ;;
    
    -fp|--force-plots)
    FORCE_PLOTS=1
    FORCEP_FLAG=" -fp "
    ;;

    -id=*|--fig=*|--plotid=*)
    PLOTID="${i#*=}"
    ;;

    *)                      # unknown option
    echo "Unkown Option: $i"
    echo -e $usage
    exit
    ;;
esac
done

# point to last chart if not provided
if [ -z "$PLOTID" ]; then 
    PLOTID=`grep '"$PLOTID" == "."' $0 | wc -l`
    PLOTID=$((PLOTID-1))
fi

mkdir -p $PLOTDIR

# run-04-11-20*: baseline
# run-04-11-21*: with mecached opts same as shenango
# run-04-(11-2[23]|12-0): varying local mem

# Shenango vs native memcached
# DATA: native: bash show.sh -s=04-11-20 
# shenango: data/run-04-11*
if [ "$PLOTID" == "1" ]; then
    plotdir=$PLOTDIR/$PLOTID
    mkdir -p $plotdir
    plotname=${plotdir}/native_xput.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        for thr in 10 25 50 75 100; do 
            datafile=$plotdir/native_xput_$thr
            if [[ $FORCE ]] || [ ! -f "$datafile" ]; then
                bash ${SCRIPT_DIR}/show.sh 04-11-20 -t=$thr -of=$datafile
            fi
            plots="$plots -dyc $datafile Xput -l kthreads:$thr"
        done
        datafile=$plotdir/native_xput_cores
        if [[ $FORCE ]] || [ ! -f "$datafile" ]; then
            bash ${SCRIPT_DIR}/show.sh 04-12-12 -of=$datafile
        fi
        plots="$plots -dyc $datafile Xput -l kthreads:=CPU"
        python3 ${SCRIPT_DIR}/../scripts/plot.py ${plots}   \
            -yl "KOPS" --ymul 1e-3 -xc CPU                  \
            --size 4 3 -fs 12 -of $PLOTEXT -o $plotname
    fi
    display ${plotname} &
fi

# With Fastswap
# DATA: bash show.sh -cs="run-04-\(11-2[23]\|12-0\)"
# DATA: bash show.sh 04-14-[01]      # cores = threads
# DATA: bash show.sh -cs="04-\(14-2\|15-\)"     # cores = threads
# DATA: bash show.sh 04-17      # cores = threads, no dirtying
if [ "$PLOTID" == "2" ]; then
    plotdir=$PLOTDIR/$PLOTID
    mkdir -p $plotdir
    plots=
    files=
    for cores in 1 2 3 4 5; do
        #data
        # for thr in 10 50 100; do 
        #     datafile=$plotdir/data_${cores}cores_${thr}thr
        #     if [[ $FORCE ]] || [ ! -f "$datafile" ]; then
        #           bash ${SCRIPT_DIR}/show.sh -cs="run-04-\(11-2[23]\|12-0\)" -c=$cores -t=$thr -of=$datafile
        #           sed -i 's/\,\([0-9]\+\)M\,/\,\1\,/g' $datafile        #HACK: to remove suffix M in localmem
        #     fi
        #     plots="$plots -d $datafile -l kthreads:$thr"
        # done
        datafile=$plotdir/native_xput_${cores}cores
        if [[ $FORCE ]] || [ ! -f "$datafile" ]; then
            bash ${SCRIPT_DIR}/show.sh -cs="04-\(14-2\|15-\)" -c=$cores -of=$datafile
            # bash ${SCRIPT_DIR}/show.sh -cs="04-\(14-2\|15-\)" -c=$cores -of=$datafile
            sed -i 's/\,\([0-9]\+\)M\,/\,\1\,/g' $datafile        #HACK: to remove suffix M in localmem
        fi

        plots="$plots -d $datafile -l $cores"
        cat $datafile
    done

    #plot xput
    plotname=${plotdir}/xput_${cores}cores.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${SCRIPT_DIR}/../scripts/plot.py ${plots}   \
            -yc Xput -yl "Xput KOPS" --ymul 1e-3 -xc LocalMem    \
            --size 4.5 3 -fs 12 -of $PLOTEXT -o $plotname -lt "CPU"
    fi
    files="$files $plotname"

    #plot faults
    plotname=${plotdir}/faults_${cores}cores.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${SCRIPT_DIR}/../scripts/plot.py ${plots}               \
            -yc "MajPGF/s" -yl "Major Faults KOPS" --ymul 1e-3 -xc LocalMem   \
            --size 4.5 3 -fs 12 -of $PLOTEXT -o $plotname -lt "CPU"
    fi
    files="$files $plotname"

    #plot rss
    plotname=${plotdir}/minfaults_${cores}cores.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${SCRIPT_DIR}/../scripts/plot.py ${plots}               \
            -yc "MinPGF/s" -yl "Minor Faults KOPS" --ymul 1e-3 -xc LocalMem   \
            --size 4.5 3 -fs 12 -of $PLOTEXT -o $plotname -lt "CPU"
    fi
    files="$files $plotname"

    # # Combine
    plotname=${plotdir}/all_${cores}cores_1.$PLOTEXT
    montage -tile 3x0 -geometry +5+5 -border 5 $files ${plotname}
    display ${plotname} &
fi

# Fastswap with error bars
# DATA: bash show.sh -cs="04-\(19\|2[01]\)"
if [ "$PLOTID" == "3" ]; then
    plotdir=$PLOTDIR/$PLOTID
    mkdir -p $plotdir
    files=
    plots=
    for cores in 1 2 3 4 5; do
        datafile=${plotdir}/data_${cores}cores
        if [[ $FORCE ]] || [ ! -f "$datafile" ]; then
            echo "cores,localmem,xput,xputerr,majpf,majpferr,minpf,minpferr" > $datafile
            for mem in `seq 1000 200 2200`; do 
                tmpfile=${TMP_FILE_PFX}_${cores}cores_${mem}M
                bash show.sh -cs="04-\(19\|2[01]\)" -c=${cores} -lm=${mem}M -of=$tmpfile

                xput=$(mean $tmpfile 10)
                xputerr=$(stdev $tmpfile 10)
                majpf=$(mean $tmpfile 16)
                majpferr=$(stdev $tmpfile 16)
                minpf=$(mean $tmpfile 17)
                minpferr=$(stdev $tmpfile 17)
                echo $cores,$mem,$xput,$xputerr,$majpf,$majpferr,$minpf,$minpferr >> $datafile
            done
        fi
        cat $datafile
        plots="$plots -d $datafile -l $cores"
    done

    #plot xput
    plotname=${plotdir}/xput_${cores}cores.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${SCRIPT_DIR}/../scripts/plot.py ${plots} --yerr xputerr    \
            -yc xput -yl "Xput KOPS" --ymul 1e-3 -xc localmem               \
            --size 4.5 3 -fs 12 -of $PLOTEXT -o $plotname -lt "CPU"
    fi
    files="$files $plotname"

    #plot faults
    plotname=${plotdir}/faults_${cores}cores.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${SCRIPT_DIR}/../scripts/plot.py ${plots} --yerr majpferr   \
            -yc majpf -yl "Major Faults KOPS" --ymul 1e-3 -xc localmem      \
            --size 4.5 3 -fs 12 -of $PLOTEXT -o $plotname -lt "CPU"
    fi
    files="$files $plotname"

    #plot rss
    plotname=${plotdir}/minfaults_${cores}cores.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${SCRIPT_DIR}/../scripts/plot.py ${plots} --yerr minpferr   \
            -yc minpf -yl "Minor Faults KOPS" --ymul 1e-3 -xc localmem      \
            --size 4.5 3 -fs 12 -of $PLOTEXT -o $plotname -lt "CPU"
    fi
    files="$files $plotname"

    # # Combine
    plotname=${plotdir}/all_${cores}cores_errorbars.$PLOTEXT
    montage -tile 3x0 -geometry +5+5 -border 5 $files ${plotname}
    display ${plotname} &
fi

# Page faults time series
# DATA: bash show.sh 04-22 -c=1
if [ "$PLOTID" == "4" ]; then
    plotdir=$PLOTDIR/$PLOTID
    mkdir -p $plotdir
    for cores in 1 2 3 4 5; do 
        files=
        preloadplots=
        sampleplots=
        expfile=${TMP_FILE_PFX}exps
        # bash ${SCRIPT_DIR}/show.sh 04-23-1[678] -c=${cores} -of=${expfile}
        bash ${SCRIPT_DIR}/show.sh 04-24 -c=${cores} -of=${expfile}
        for line in `tail -n+2 $expfile`; do 
            exp=$(echo $line | awk -F, '{ print $1 }')
            lmem=$(echo $line | awk -F, '{ print $6 }')
            data=data/$exp/
            preload_start=$(cat $data/preload_start 2>/dev/null)
            preload_end=$(cat $data/preload_end 2>/dev/null)
            sample_start=$(cat $data/sample_start 2>/dev/null)
            sample_end=$(cat $data/sample_end 2>/dev/null)
            pgfile=$data/sar_pgfaults_majflts_preload
            if [[ $FORCE ]] || [ ! -f $pgfile ]; then 
                bash parse_sar.sh -n=${exp} -sf=pgfaults -sc=majflt/s \
                    -t1=$preload_start -t2=$sample_start -of=$pgfile; 
            fi
            preloadplots="$preloadplots -d $pgfile -l $lmem"
            pgfile=$data/sar_pgfaults_majflts
            if [[ $FORCE ]] || [ ! -f $pgfile ]; then 
                bash parse_sar.sh -n=${exp} -sf=pgfaults -sc=majflt/s \
                    -t1=$sample_start -t2=$sample_end -of=$pgfile; 
            fi
            sampleplots="$sampleplots -d $pgfile -l $lmem"
        done
        if [[ $sampleplots ]]; then 
            plotname=${plotdir}/preload_faults_${cores}cores.${PLOTEXT}
            if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
                python3 ${SCRIPT_DIR}/../scripts/plot.py ${preloadplots} \
                    -yc "majflt/s" -yl "Major Faults KOPS" --ymul 1e-3  \
                    --ymin 0 --ymax 100  --vlines $checkpts             \
                    --size 5 3 -fs 12 -of $PLOTEXT -o $plotname -lt "LocalMem"
            fi
            files="$files $plotname"
            plotname=${plotdir}/sample_faults_${cores}cores.${PLOTEXT}
            if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
                python3 ${SCRIPT_DIR}/../scripts/plot.py ${sampleplots} \
                    -yc "majflt/s" -yl "Major Faults KOPS" --ymul 1e-3  \
                    --ymin 0 --ymax 100  --vlines $checkpts             \
                    --size 5 3 -fs 12 -of $PLOTEXT -o $plotname -lt "LocalMem"
            fi
            files="$files $plotname"

            # Combine
            plotname=${plotdir}/all_faults_${cores}cores.$PLOTEXT
            montage -tile 2x0 -geometry +5+5 -border 5 $files ${plotname}
            display ${plotname} &
        fi
    done
fi

# cleanup
rm -f ${TMP_FILE_PFX}*