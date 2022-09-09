# for i in `seq 1 1 10`; do 
    for cores in 1; do
        # for mem in `seq 1000 200 2200`; do 
        for mem in 1000; do 
            bash run.sh -d='no-dirty;no-printing' -c=$cores -t=$cores -m="${mem}M" 
        done
        sleep 5
    done
# done

# cores=2
# mem=1000M
# for i in `seq 1 1 10run-04-17-13-36`; do 
#     bash run.sh -d='testing variance; with udp' -c=$cores -t=$cores -m=$mem --udp
#     sleep 10
# done