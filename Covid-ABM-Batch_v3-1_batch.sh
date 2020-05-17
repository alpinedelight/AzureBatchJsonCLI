#!/bin/bash
echo "Bash version ${BASH_VERSION}..."

# https://docs.microsoft.com/en-us/cli/azure/authenticate-azure-cli
#az login 
#az account set --subscription "Jomallin MSFT Subscription"
az batch account login --name 'aeolus' --resource-group 'DataReplication-Dev-RG'

##### PARAMETERS
# batch account details
clustername='Cluster-X1'
clustervmtype='Standard_E32_v3'
clustercmd='/bin/bash -c "apt update && apt -q -y install libgsl23"'
dedicatednodes=2
lowprinodes=1
nodeconcurrenttasks=32
jobnamesuffix=`date '+%Y%m%d%H%M%S'`
# rf resource files storage
rf_account='aeolus'
rf_resource_container='covid'
rf_results_container='covidresults'
# job definition
joblistfile='./joblist1test.csv'

mkdir ./tmp/ #to hold generated json batch defintions (cluster, jobs, tasks)

##### CREATE CLUSTER
echo "Create Cluster: $clustername, $dedicatednodes (x$nodeconcurrenttasks), $clustervmtype"
jq --arg cn "$clustername" --arg cvm "$clustervmtype" --arg n $dedicatednodes --arg lpn $lowprinodes --arg nct "$nodeconcurrenttasks" --arg cmd "$clustercmd" '.id=$cn | .displayName=$cn | .vmSize=$cvm | .scaleSettings.fixedScale.targetDedicatedNodes=($n|tonumber) | .scaleSettings.fixedScale.targetLowPriorityNodes=($lpn|tonumber) | .maxTasksPerNode=$nct | .startTask.commandLine=$cmd' clusterdefinition.json > ./tmp/cluster.json
az batch pool create --json-file ./tmp/cluster.json

#az batch pool resize \
#    --pool-id $clustername \
#    --target-dedicated 5
#az batch pool show --pool-id $clustername

##### PREPARE INPUT/RESOURCE FILES
# create SAS token for resource files - 
# create one token for container as opposed to individual blob SAS tokens
# other methods include account key (god-mode) or public access, this is safer
echo "CREATE SAS Tokens - in: $rf_account@$rf_resource_container out: $rf_account@$rf_results_container"
sas_in=`az storage container generate-sas \
    --account-name $rf_account \
    --name $rf_resource_container \
    --permissions acrw \
    --expiry $(date '+%Y-%m-%d' -d "+2 days") \
    --auth-mode login \
    --as-user`
sas_in=${sas_in:1:-1} # remove quotes

# the results can be stored in a seperate container, and or storage account
sas_out=`az storage container generate-sas \
    --account-name $rf_account \
    --name $rf_results_container \
    --permissions acrw \
    --expiry $(date '+%Y-%m-%d' -d "+2 days") \
    --auth-mode login \
    --as-user`
sas_out=${sas_out:1:-1} # remove quotes

outbaseurl=$(az storage account show --name $rf_account --query 'primaryEndpoints.blob' --output tsv)


##### CREATE JOBS
# Based on joblist.csv folder (format 4cols no header, jobname,startparam,endparm,stepparam)
#readarray -t joblist < ./joblist.csv # get a list of jobs, jobname,start,end,step

IFS=$'\r\n' read -d '' -r -a joblist < "${joblistfile}"
echo "Create jobs based of $joblistfile"
printf '%s\n' ${joblist[@]}

for i in "${!joblist[@]}"; do
    jc=(${joblist[i]//,/ }) #get job config
    jobname="${jc[0]}_$jobnamesuffix"
    jobnameclean="${jc[0]}"
    pstart=${jc[1]} #aimed at paramter sweeps
    pend=${jc[2]}
    pstep=${jc[3]}

    prepcmd='/bin/bash -c "printenv && mkdir $AZ_BATCH_NODE_SHARED_DIR/@@jobname && mv $AZ_BATCH_TASK_WORKING_DIR/* $AZ_BATCH_NODE_SHARED_DIR/@@jobname"'
    prepcmd=${prepcmd//@@jobname/$jobname} #substitute variable
    #echo "$i $jobname: $pstart $pend $pstep" 

    # Get list of files we want to seed for each job
    # use prefix to filter specific files, i.e. all files starting with london_*
    # opportunity to simplify code... review later, also can use the prefix variable!
    rf_list=''
    NL=$'\n'

    echo "Creating file list: $jobname"
    # get global resource files, i.e. national demographic data
    blobs=`az storage blob list --container-name $rf_resource_container --prefix baseline_ --account-name $rf_account --auth-mode login --query '[].{name:name}' --output tsv`
    for b in $blobs; 
    do 
        b_url=`az storage blob url --account-name $rf_account --sas-token $sas_in --container-name $rf_resource_container --name $b`
        b_url=${b_url:1:-1} # remove quotes
        rf_list+="$b $b_url${NL}"
    done

    # get job specific resource files 
    blobs=`az storage blob list --container-name $rf_resource_container --prefix $jobnameclean --account-name $rf_account --auth-mode login --query '[].{name:name}' --output tsv`
    for b in $blobs; 
    do 
        b_url=`az storage blob url --account-name $rf_account --sas-token $sas_in --container-name $rf_resource_container --name $b`
        b_url=${b_url:1:-1} # remove quotes
        rf_list+="$b $b_url${NL}"
    done
    # for each new line create array item, then split items by space and convert to array of json objects
    rfjson=$((jq -R -s 'split("\n") | select(length > 0)' <<< "$rf_list") | jq -c 'map( split(" ") | select(length > 0) | {filePath:.[0],httpUrl:.[1]})')

    # generate job json object
    jq --arg jn "$jobname" --arg cn "$clustername" --arg pcmd "$prepcmd" --argjson rf $rfjson '.id=$jn | .poolInfo.poolId=$cn | .jobPreparationTask.commandLine=$pcmd | .jobPreparationTask.resourceFiles=$rf' jobdefinition.json > ./tmp/job.json
    #echo "Generated job json:"
    #jq '.' tmpjob.json
    echo "Submitting job: $jobname"
    az batch job create --json-file ./tmp/job.json

    ##### CREATE TASKS
    # Create 1 task for each permuation as defined in jobconfig params
    # Batch tasks together, cli batch maximum is 100 tasks per call, thus need to track
    maxtaskpercall=100
    taskcounter=0
    taskjsonlist=() # create array to hold json objects
    url="$outbaseurl$rf_results_container?$sas_out" # get output container url + sas
    
    echo "Creating tasks"
    for (( t=pstart; t <= $pend; t+=$pstep, taskcounter++))
    do 
        #echo "Task $t"
        tid=$t
        taskid="task$tid"

        outpath="$jobname/$taskid"
        filepattern="**/individual*.csv"
    
        taskcmd='/bin/bash -c "$AZ_BATCH_APP_PACKAGE_covid19ibm_1/covid19ibm.exe $AZ_BATCH_NODE_SHARED_DIR/@@jobname/@@jobfile_parameters.csv @@param $AZ_BATCH_TASK_WORKING_DIR/ $AZ_BATCH_NODE_SHARED_DIR/@@jobname/baseline_household_demographics.csv"'
        taskcmd=${taskcmd//@@param/$tid} #$tid
        taskcmd=${taskcmd//@@jobname/$jobname} 
        taskcmd=${taskcmd//@@jobfile/$jobnameclean}

        #jq --arg t "$taskid" --arg cmd "$taskcmd" --arg bloburl "$url" --arg outpath "$outpath" --arg fp "$filepattern" '.id=$t | .displayName=$t |.commandLine=$cmd | .outputFiles[].destination.container.containerUrl=$bloburl | .outputFiles[].destination.container.path=$outpath | .outputFiles[].filePattern=$fp' taskdefinition.json >tmptask.json
        taskjson=$(jq -c --arg t "$taskid" --arg cmd "$taskcmd" --arg bloburl "$url" --arg outpath "$outpath" --arg fp "$filepattern" '.id=$t | .displayName=$t |.commandLine=$cmd | .outputFiles[].destination.container.containerUrl=$bloburl | .outputFiles[].destination.container.path=$outpath | .outputFiles[].filePattern=$fp' taskdefinition.json)
        taskjsonlist+=("$taskjson")

        # if we have piled up 100 tasks, submit
        if [ $((taskcounter)) -ge $((maxtaskpercall)) ]
        then
            printf -v myvar '%s,' "${taskjsonlist[@]}" 
            echo "[$myvar]" > ./tmp/task.json
            echo "Sending task batch: $jobname idx $t cnt ${#taskjsonlist[@]}"
            #$(jq -R -s -n 'split("\n")' <<< printf '%s\n' "${taskjsonlist[@]}") > ./tmp/task.json
            (az batch task create --job-id $jobname --json-file ./tmp/task.json) >> taskout.log
            taskcounter=0 # reset counter
            taskjsonlist=()
        fi
    done

    # if there are remaining tasks submit those
    if [ $((taskcounter)) -ge 0 ]
    then
        echo "Sending remaining tasks: $jobname idx $t cnt ${#taskjsonlist[@]}"
        #$(jq -Rn 'split("\n") | select(length > 0)' <<< printf '%s\n' "${taskjsonlist[@]}") > ./tmp/task.json
        printf -v myvar '%s,' "${taskjsonlist[@]}" 
        echo "[$myvar]" > ./tmp/task.json
        (az batch task create --job-id $jobname --json-file ./tmp/task.json) >> taskout.log
        taskcounter=0 # reset counter
        taskjsonlist=()
    fi

    # Update the job so that it is automatically
    # marked as completed once all the tasks are finished.
    az batch job set \
    --job-id $jobname \
    --on-all-tasks-complete terminatejob
done