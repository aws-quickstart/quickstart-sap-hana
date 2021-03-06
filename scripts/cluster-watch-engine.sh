#!/bin/bash


# ------------------------------------------------------------------
# 
#          Watches HANA Cluster
#          Uses dynamodb as a proxy to maintain status of HANA nodes
#          Valid states are 
#          TABLE_INIT_COMPLETE
#               PRE_INSTALL_COMPLETE
#                   |HANDSHAKE
#                       |POST_INSTALL
#                           |COMPLETE
#                               |RUNNING
# ------------------------------------------------------------------


TEST_ENVIRON=0
TEST_IP=${RANDOM}


JQ_COMMAND=/root/install/jq
export PATH=${PATH}:/sbin:/usr/sbin:/usr/local/sbin:/root/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin/X11:/usr/X11R6/bin:/usr/games:/usr/lib/AmazonEC2/ec2-api-tools/bin:/usr/lib/AmazonEC2/ec2-ami-tools/bin:/usr/lib/mit/bin:/usr/lib/mit/sbin

usage() { 
    cat <<EOF
    Usage: $0 [options]
        -h print usage
        -c Create DyanamoDB Table
        -b Block until table is created 
        -r Delete table
        -s Update Status
        -i Insert/Update Item (key=value pair)
        -n Table Name (default: HANAMonitor)
        -q Query number of HANA nodes in a given state 
        -w Wait until #HANA nodes reach a specific state (status=N)
        -p Print Table 
EOF
    exit 0
}


# ------------------------------------------------------------------
#          Read all inputs
# ------------------------------------------------------------------


CREATE=0
PRINT=0
BLOCK_UNTIL_TABLE_LIVE=0
DELETE_TABLE=0
NUM_RETRY=0
MAX_RETRIES=10

[[ $# -eq 0 ]] && usage;

while getopts "hcbprs:i:n:q:w:" o; do
    case "${o}" in
        h) usage && exit 0
            ;;
        c) CREATE=1
            ;;
        p) PRINT=1
            ;;
		b) BLOCK_UNTIL_TABLE_LIVE=1
			;;
		r) DELETE_TABLE=1
			;;
        q) QUERY_STATUS=${OPTARG}
            ;;
        s) NEW_STATUS=${OPTARG}
            ;;
        i) NEW_ITEM_PAIR=${OPTARG}
            ;;
        n) TABLE_NAME=${OPTARG}
            ;;
        w) WAIT_STATUS_COUNT_PAIR=${OPTARG}
            ;;
        *) 
            usage
            ;;
    esac
done

# ------------------------------------------------------------------
#          Make sure all input parameters are filled
# ------------------------------------------------------------------
source /root/install/config.sh                    
source /root/install/os.sh                    
                    
[[ -z "$TABLE_NAME" ]] && source /root/install/config.sh
shift $((OPTIND-1))
[[ $# -gt 0 ]] && usage;

SCRIPT_DIR=/root/install/
if [ -z "${HANA_LOG_FILE}" ] ; then
    HANA_LOG_FILE=${SCRIPT_DIR}/install.log
fi

log() {
    echo $* 2>&1 | tee -a ${HANA_LOG_FILE}
}


source /root/install/config.sh 
export AWS_DEFAULT_REGION=${REGION}

# ------------------------------------------------------------------
#          Status of Table creation
# ------------------------------------------------------------------

#Check if SIG_FLAG_FILE is present

if [ $(issignal_check) == 1 ] 
then
    #Exit since there is a signal file
    log "Exiting $0 script at `date` because $SIG_FLAG_FILE exists"
    exit 1
fi

GetCreationStatus() {
    status=$(${AWSCLI_BIN} dynamodb describe-table --table-name ${TABLE_NAME} --query Table.TableStatus)
    echo $status
}

WaitUntilTableActive() {
    while true; do
        status=$(GetCreationStatus)
		log "${TABLE_NAME}:${status}"
		log ${status}
        case "$status" in
          *ACTIVE* ) break;;
        esac
    sleep 10
    done 
}


IfTableFound() {
    status=$(${AWSCLI_BIN} dynamodb describe-table --table-name ${TABLE_NAME} 2>&1)
    if [[ "${status}" == *"not found"* ]]; then
       echo 0
    else
       echo 1
    fi
}


# ------------------------------------------------------------------
#    Used in multinode scenario when master created the table
#	 Worker nodes will just wait until table is ready
# ------------------------------------------------------------------

WaitUntilTableLive() {
    while true; do
        status=$(IfTableFound)
		if [ $status -eq 0 ]; then
			echo "Waiting for Master to create table.."
			sleep 10
		else
			echo "Master has created table!"
			break
		fi
	done
}


# ------------------------------------------------------------------
#    Wait until table is fully deleted!
# ------------------------------------------------------------------

WaitUntilTableDead() {
    while true; do
        status=$(IfTableFound)
		if [ $status -eq 1 ]; then
			echo "Waiting for table delete to complete!.."
			sleep 10
		else
			echo "Master has deleted table!"
			break
		fi
	done
}

# ------------------------------------------------------------------
#          Create dynamodb table to track HANA nodes
# ------------------------------------------------------------------

CreateTable() {
	log "CreateTable ${TABLE_NAME} in cluster-watch-engine.sh "
    ${AWSCLI_BIN} dynamodb create-table \
        --table-name ${TABLE_NAME} \
        --attribute-definitions \
            AttributeName=PrivateIpAddress,AttributeType=S \
        --key-schema \
            AttributeName=PrivateIpAddress,KeyType=HASH \
        --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1 >> ${HANA_LOG_FILE} 2>&1
    
    rc=$?
    
    if [ $rc -lt 0 ]; then
        # CreateTable failed - retry max 10 times
        if [ ${NUM_RETRY} -lt ${MAX_RETRIES} ]; then
            NUM_RETRY=$((NUM_RETRY+1))
            CreateTable
        fi
    fi
    
    log "Waiting for table creation"
    WaitUntilTableActive
    log "DynamoDB Table: ${TABLE_NAME} Ready!"

}

# ------------------------------------------------------------------
#          Delete table to make a clean start deploy
# ------------------------------------------------------------------

DeleteTable() {
	status=$(IfTableFound)
	if [ $status -eq 0 ]; then
		echo "Table doesn't exist. No need to delete"
		return
	fi
	status=$(${AWSCLI_BIN} dynamodb delete-table --table-name ${TABLE_NAME})
	WaitUntilTableDead
}

GetMyIp() {
    if which ifconfig >/dev/null 2>&1
    then
        ip=$(ifconfig eth0 | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}')
    else
        ip=$(ip route get 1.2.3.4 | awk '{print $7}')
    fi  
    # Begin RHEL 7.2  addition
    if [ "$ip" == "" ]; then
        ip=$(ifconfig eth0 | grep 'inet ' | cut -d: -f2 | awk '{ print $2}')
    fi
    # End RHEL 7.2 addition
    if [ $TEST_ENVIRON -eq 1 ]; then
        echo ${TEST_IP}
    else
        echo ${ip}
    fi
}



# ------------------------------------------------------------------
#          Update or insert table item with new key=value pair
#          New attributes get added, old attributes get updated
#          Use private ip as primary hash key
#          Usage InsertMyKeyValueS key=value
# ------------------------------------------------------------------

InsertMyKeyValueS() {

    keyvalue=$1
    if [ -z "$keyvalue" ]; then
        echo "Invalid KeyPair Values!"
        return
    fi
    key=$(echo $keyvalue | awk -F'=' '{print $1}')
    value=$(echo $keyvalue | awk -F'=' '{print $2}')

    keyjson_template='{"PrivateIpAddress": {
        "S": "myip"
        }}'
    myip=$(GetMyIp)  
    keyjson=$(echo -n ${keyjson_template} | sed "s/myip/${myip}/g")

    insertjson_template='{"key": {
                "Value": {
                    "S": "value"
                },
                "Action": "PUT"
            }
        }'

    insertjson=$(echo -n ${insertjson_template} | sed "s/key/${key}/g")    
    insertjson=$(echo -n ${insertjson} | sed "s/value/${value}/g")    
    cmd=$(echo  "${AWSCLI_BIN} dynamodb update-item --table-name ${TABLE_NAME} --key '${keyjson}' --attribute-updates '${insertjson}'")
	log "${cmd}"	
    echo ${cmd} | sh 


}

# ------------------------------------------------------------------
#          Initialize the dynamodb table
# ------------------------------------------------------------------

InitMyTable() {
    myip=$(GetMyIp)
    json_template='{ "PrivateIpAddress": {"S": "myip" }, 
            "Status": {"S": "TABLE_INIT_COMPLETE"},
            "StatusAck": {"S": "TABLE_INIT_COMPLETE_ACK"}
        }'
    json_template='{ "PrivateIpAddress": {"S": "myip" }}'
    json=$(echo ${json_template} | sed "s/myip/${myip}/g")
    ${AWSCLI_BIN} dynamodb put-item --table-name ${TABLE_NAME}  --item "${json}"
    instanceid=$(curl http://169.254.169.254/latest/meta-data/instance-id)
    InsertMyKeyValueS "InstanceId=${instanceid}"
}

# ------------------------------------------------------------------
#          Use private ip as primary hash key
#          Set Status of HANA Nodes (valid ones below)
#          TABLE_INIT_COMPLETE
#               PRE_INSTALL_COMPLETE
#                   |HANDSHAKE
#                       |POST_INSTALL
#                           |COMPLETE
#                               |RUNNING
# ------------------------------------------------------------------

SetMyStatus() {
    status=$1
    if [ -z "$status" ]; then
        echo "Invalid Status Update!"
        return
    fi
    keyjson_template='{"PrivateIpAddress": {
        "S": "myip"
        }}'
    myip=$(GetMyIp)    
    keyjson=$(echo -n ${keyjson_template} | sed "s/myip/${myip}/g")

    updatejson_template='{"Status": {
                "Value": {
                    "S": "mystatus"
                },
                "Action": "PUT"
            }
        }'

    updatejson=$(echo -n ${updatejson_template} | sed "s/mystatus/${status}/g")    
    cmd=$(echo  "${AWSCLI_BIN} dynamodb update-item --table-name ${TABLE_NAME} --key '${keyjson}' --attribute-updates '${updatejson}'")
    echo ${cmd} | sh 

}


# ------------------------------------------------------------------
#          Count number of HANA hosts in specific state
#          Usage: QueryStatusCount "PRE_INSTALL_COMPLETE" etc
#          Set Status of HANA Nodes (valid ones below)
#               PRE_INSTALL_COMPLETE
#                   |HANDSHAKE
#                       |POST_INSTALL
#                           |COMPLETE
#                               |RUNNING
# ------------------------------------------------------------------

QueryStatusCount(){
    status=$1
    if [ -z "$status" ]; then
        echo "StatusCountQuery invalid!"
        return 
    fi
   ${AWSCLI_BIN} dynamodb scan --table-name ${TABLE_NAME} --scan-filter '
            { "Status" : {
                "AttributeValueList": [
                    {
                        "S": '\"${status}\"'
                    }
                ],
                "ComparisonOperator":"EQ"
                }} ' --region ${AWS_DEFAULT_REGION} >> ${HANA_LOG_FILE} 2>&1

    ${AWSCLI_BIN} dynamodb scan --table-name ${TABLE_NAME} --scan-filter '
            { "Status" : {
                "AttributeValueList": [
                    {
                        "S": '\"${status}\"'
                    }
                ],
                "ComparisonOperator":"EQ"
                }} ' --region ${AWS_DEFAULT_REGION} | ${JQ_COMMAND}  '.Items[]|.PrivateIpAddress|.S'  >> ${HANA_LOG_FILE} 2>&1


    count=$(${AWSCLI_BIN} dynamodb scan --table-name ${TABLE_NAME} --scan-filter '
            { "Status" : {
                "AttributeValueList": [
                    {
                        "S": '\"${status}\"'
                    }
                ],
                "ComparisonOperator":"EQ"
                }} ' --region ${AWS_DEFAULT_REGION}| ${JQ_COMMAND}  '.Items[]|.PrivateIpAddress|.S' | wc -l)
    echo ${count}
}


# ------------------------------------------------------------------
#          Wait until specific #HANA hosts reach specific state
#          Usage: WaitUntilStatus "PRE_INSTALL_COMPLETE" 5 etc.
#          Wait until 5 HANA nodes reach "PRE_INSTALL_COMPLETE" status
# ------------------------------------------------------------------

WaitForSpecificStatus() {
	log "WaitForSpecificStatus START ($1) in cluster-watch-engine.sh"

    status_count_pair=$1
    if [ -z "$status_count_pair" ]; then
        echo "Invalid Status=count Values!"
        return
    fi
	log "Received ${status_count_pair} in cluster-watch-engine.sh"
    status=$(echo $status_count_pair | /usr/bin/awk -F'=' '{print $1}')
    expected_count=$(echo $status_count_pair | /usr/bin/awk -F'=' '{print $2}')
	log "Checking for ${status} = ${expected_count} times"

    while true; do
       log "${AWSCLI_BIN} dynamodb scan --table-name ${TABLE_NAME} --region ${AWS_DEFAULT_REGION}"
       TABLE_VALUES=$(${AWSCLI_BIN} dynamodb scan --table-name ${TABLE_NAME} --region ${AWS_DEFAULT_REGION})
       log "${TABLE_VALUES}"

       ${AWSCLI_BIN} dynamodb scan --table-name ${TABLE_NAME} --region ${AWS_DEFAULT_REGION}>> ${HANA_LOG_FILE} 2>&1

       log "Calling QueryStatusCount ${status}"
        count=$(QueryStatusCount ${status})
	log "${status}: ${count} in cluster-watch-engine.sh."
        if [ "${count}" -lt "${expected_count}" ]; then
            log "${count}/${expected_count} in ${status} status...Waiting"
			sleep 10
       else
            log "${count} out of ${expected_count} in ${status} status!"
            log "WaitForSpecificStatus END ($1) in cluster-watch-engine.sh"
            return
        fi
    done 
	


}

# ------------------------------------------------------------------
#          Print table
# ------------------------------------------------------------------

Print() {
    ${AWSCLI_BIN} dynamodb scan --table-name ${TABLE_NAME}
}




if [ $CREATE -eq 1 ]; then
    CreateTable ${TABLE_NAME}
    InitMyTable
fi

if [ $NEW_STATUS ]; then
    SetMyStatus ${NEW_STATUS}
fi

if [ $NEW_ITEM_PAIR ]; then
    InsertMyKeyValueS ${NEW_ITEM_PAIR}
fi

if [ $QUERY_STATUS ]; then
    QueryStatusCount $QUERY_STATUS
fi


if [ $WAIT_STATUS_COUNT_PAIR ]; then
    WaitForSpecificStatus $WAIT_STATUS_COUNT_PAIR
fi


if [ $PRINT -eq 1 ]; then
    Print
fi

if [ $BLOCK_UNTIL_TABLE_LIVE -eq 1 ]; then
	WaitUntilTableLive
fi

if [ $DELETE_TABLE -eq 1 ]; then
	DeleteTable
fi



if [ $TEST_ENVIRON -eq 1 ]; then
    CreateTable
    for i in {1..10}
    do
        SetMyStatus "READY"
    done
    for i in {1..10}
    do
        SetMyStatus "COMPLETE"
    done
fi

