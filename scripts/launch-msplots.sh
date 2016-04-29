#!/bin/bash
# This script is to be called from lfe001 and will launch msplots
# instances on all non-developer compute nodes. Any arguments are passed
# directly to the msplots instances.
# cexec1 is used because it allows us to address each lce node by the same
# number as in its name. The script assumes that msplots is in the PATH
# and that the pyautoplot module is in the PYTHONPATH.

HOSTNAME=`hostname`
PATH="$PATH:/opt/cep/pyautoplot/bin"
INSPECT_ROOT=/globaldata/inspect
LOG=$INSPECT_ROOT/launch-msplots.log


#Time to wait for stuck processes before killing them
export ALARMTIME=420
 
PARENTPID=$$
GLOBAL_ARGS=$@
COMMAND_NAME="msplots $@"


function remote_parset_lookup() {
    parset_host=$1
    sas_id=$2
    parset_key=$3

    ssh $parset_host "grep $parset_key /localhome/lofarsystem/parsets/rtcp-$sas_id.parset" 2>/dev/null;
}


function sas_id_project() {
    sas_id=$1
    remote_parset_lookup cbm001 $sas_id 'Observation.Campaign.name'|sed -e's/=/ /g' -e 's/"/ /g'|awk '{ print $2 }';
}


function hostname_fqdn() {
    # Return the fully qualified domain name of a LOFAR server
    # Sadly -- on some machines -- hostname returns the FQDN
    # while hostname -f returns the short name >_<
    (hostname;hostname -f)|awk '{ print length, $0 }' | sort -n -s | cut -d" " -f2-
}


function cep_cluster(){
    case `hostname_fqdn` in
        *cep2*) echo CEP2;;
        *cep4*) echo CEP4;;
        *) echo OTHER;;
    esac
}


function create_html_fn() {
    CREATE_HTML=`which create_html`
    echo "$GLOBAL_ARGS" | tee -a $LOG
    if test "$CREATE_HTML" == ""; then
        echo "Cannot find create_html: no HTML generated" | tee -a $LOG

    else
        echo "Creating HTML using $CREATE_HTML" | tee -a $LOG
        command="$CREATE_HTML $GLOBAL_ARGS"
        echo "$command"| tee -a $LOG
        result=`$command`
        exit_status="$?"
        if test "$exit_status" == "0"; then
            echo "HTML Created successfully" | tee -a $LOG
        else 
            echo "Problem creating HTML overview for $GLOBAL_ARGS." | tee -a $LOG
            echo "Exit status: $exit_status" | tee -a $LOG
            echo "$result" | tee -a $LOG
        fi
    fi
}

function create_html_remotely_fn() {
    REMOTE_HOST=$1
    CREATE_HTML=`ssh $REMOTE_HOST which create_html`
    ssh $REMOTE_HOST "echo \"$GLOBAL_ARGS\" | tee -a $LOG"
    if test "$CREATE_HTML" == ""; then
        echo "Cannot find create_html: no HTML generated" | tee -a $LOG

    else
        ssh $REMOTE_HOST "echo \"Creating HTML using $CREATE_HTML\" | tee -a $LOG"
        command="$CREATE_HTML $GLOBAL_ARGS"
        ssh $REMOTE_HOST "echo \"$command\"| tee -a $LOG"
        result=`ssh $REMOTE_HOST "bash -ilc \"use Lofar; use Pyautoplot; $command\""`
        exit_status="$?"
        if test "$exit_status" == "0"; then
            ssh $REMOTE_HOST "echo \"HTML Created successfully\" | tee -a $LOG"
        else 
            ssh $REMOTE_HOST "echo \"Problem creating HTML overview for $GLOBAL_ARGS.\" | tee -a $LOG"
            ssh $REMOTE_HOST "echo \"Exit status: $exit_status\" | tee -a $LOG"
            ssh $REMOTE_HOST "echo \"$result\" | tee -a $LOG"
        fi
    fi
}


function exit_timeout() {
    echo "TIMEOUT : killing cexec ($CEXEC_PID)" | tee -a $LOG
    child_pids=`ps -o user,pid,ppid,command ax |grep "$COMMAND_NAME"|grep -v grep|awk '{print $2}'`
    kill $CEXEC_PID >/dev/null 2>&1
    sleep 1;
    for pid in $child_pids; do
        kill $pid > /dev/null 2>&1
        done
    sleep 5;
    kill -9 $CEXEC_PID >/dev/null 2>&1
    sleep 1;
    for pid in $child_pids; do
        kill -9 $pid > /dev/null 2>&1
        done
    sleep 1;

    for sas_id in $GLOBAL_ARGS; do
        report_global_status ${sas_id}
        done
    for sas_id in $GLOBAL_ARGS; do
        ssh -n -t -x kis001 "/home/fallows/inspect_bsts_msplots.bash $sas_id"
    done
    create_html_fn
    DATE_DONE=`date`
    echo "Done at $DATE_DONE" | tee -a $LOG
    exit
}


function sigterm_handler() {
    for sas_id in $GLOBAL_ARGS; do
        ssh lofarsys@lhn001.cep2.lofar "bash -ilc \"use Lofar; use Pyautoplot; report_global_status ${sas_id}\""
        done
    for sas_id in $GLOBAL_ARGS; do
        ssh -n -t -x kis001 "/home/fallows/inspect_bsts_msplots.bash $sas_id"
    done
    create_html_remotely_fn lofarsys@lhn001.cep2.lofar
    DATE_DONE=`date`
    ssh lofarsys@lhn001.cep2.lofar "echo \"Done at $DATE_DONE\" | tee -a $LOG"
    exit
}





case hostname_fqdn in
    lhn001*)
        DATE=`date`
        echo "" | tee -a $LOG
        echo "=======================" | tee -a $LOG
        echo "Date: $DATE"|tee -a $LOG
        echo "$0 $@" | tee -a $LOG
        echo "On machine $HOSTNAME" | tee -a $LOG
        for sas_id in $@; do
            mkdir -v $INSPECT_ROOT/$sas_id $INSPECT_ROOT/HTML/$sas_id 2>&1 | tee -a $LOG
        done

        sleep 45 # to make sure writing of metadata in MSses has a reasonable chance to finish before plots are created.
    
        #Prepare to catch SIGALRM, call exit_timeout
        trap exit_timeout SIGALRM
        
        cexec locus: "bash -ilc \"use Lofar; use Pyautoplot; $COMMAND_NAME\"" &
        CEXEC_PID=$!
        #Sleep in a subprocess, then signal parent with ALRM
        (sleep $ALARMTIME; kill -ALRM $PARENTPID) &
        #Record PID of subprocess
        ALARMPID=$!
        
        #Wait for child processes to complete normally
        wait $CEXEC_PID
 
        #Tidy up the Alarm subprocess
        kill $ALARMPID > /dev/null 2>&1
    
        for sas_id in $@; do
            report_global_status ${sas_id}
        done

        for sas_id in $@; do
            ssh -n -t -x kis001 "/home/fallows/inspect_bsts_msplots.bash $sas_id"
        done
    
        create_html_fn
        ;;

    
    *cep4*)
        DATE=`date`
        ssh lofarsys@cep2.lofar "echo \"\" | tee -a $LOG"
        ssh lofarsys@cep2.lofar "echo \"=======================\" | tee -a $LOG"
        ssh lofarsys@cep2.lofar "echo \"Date: $DATE\"|tee -a $LOG"
        ssh lofarsys@cep2.lofar "echo \"$0 $@\" | tee -a $LOG"
        ssh lofarsys@cep2.lofar "echo \"On machine $HOSTNAME\" | tee -a $LOG"
        
        for sas_id in $@; do
            ssh -A lofarsys@lhn001.cep2.lofar "mkdir -v $INSPECT_ROOT/$sas_id $INSPECT_ROOT/HTML/$sas_id 2>&1 | tee -a $LOG"
        done
        sleep 45 # to make sure writing of metadata in MSses has a reasonable chance to finish before plots are created.

        SSH_PIDS=""
        for sas_id in $@; do
            project=`sas_id_project $sas_id`
            data_products_full_path=`find /data/projects/$project/L$sas_id/ -iname "*.MS"`

            for product in $data_products_full_path; do
                # Submit slurm jobs that start docker containers at cpuxx nodes...
                ssh -n -tt -x localhost \
                    srun --exclusive --ntasks=1 --cpus-per-task=1  --job-name="msplots $product" \
                        docker run --rm -e LUSER={uid} \
                        -v /data:/data \
                        -v $HOME/.ssh:/home/lofar/ssh:ro \
                        --net=host \
                        pyautoplot:latest \
                        "/bin/bash -c \"msplots --prefix=/dev/shm/ --output=$sas_id --memory=1.0 $product ; rsync -a /dev/shm/$sas_id/ lofarsys@lhn001.cep2.lofar:$INSPECT_ROOT/$sas_id/\"" &
                SSH_PIDS="$SSH_PIDS $!"
            done
        done
        wait $SSH_PIDS
        for sas_id in $@; do
            ssh lofarsys@lhn001.cep2.lofar "bash -ilc \"use Lofar; use Pyautoplot; report_global_status ${sas_id}\""
        done

        for sas_id in $@; do
            ssh -n -t -x kis001 "/home/fallows/inspect_bsts_msplots.bash $sas_id"
        done
    
        create_html_remotely_fn lofarsys@lhn001.cep2.lofar
        ;;

    
    *)
        echo "Only thought of CEP2 and CEP4 for now"
        ;;
esac
DATE_DONE=`date`
echo "Done at $DATE_DONE" | tee -a $LOG
