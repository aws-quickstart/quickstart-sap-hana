#
# ------------------------------------------------------------------
#          Install aws cli tools and jq
# ------------------------------------------------------------------


SCRIPT_DIR=/root/install/
cd ${SCRIPT_DIR}

if [ -z "${HANA_LOG_FILE}" ] ; then
    HANA_LOG_FILE=${SCRIPT_DIR}/install.log
fi

log() {
    echo $* 2>&1 | tee -a ${HANA_LOG_FILE}
}

log `date` BEGIN install-aws

echo -n "Looking for python binary...."
PYTHON_BIN=$(which python 2>&1 > /dev/null) 

if [ $? == 0 ]; then
   PYTHON_BIN=$(which python)
   echo "export PYTHON_BIN=${PYTHON_BIN}" >> ${SCRIPT_DIR}/config.sh
   echo "...found python in ${PYTHON_BIN}"
else 
   PYTHON_BIN=$(which python3)
   echo "export PYTHON_BIN=${PYTHON_BIN}" >> ${SCRIPT_DIR}/config.sh
   echo "...found python in ${PYTHON_BIN}"
fi

wget https://s3.amazonaws.com/aws-cli/awscli-bundle.zip | tee -a ${HANA_LOG_FILE}
zypper -n install unzip
unzip awscli-bundle.zip | tee -a ${HANA_LOG_FILE}
#sudo ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws | tee -a ${HANA_LOG_FILE}
${PYTHON_BIN} /root/install/awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws | tee -a ${HANA_LOG_FILE}


# ------------------------------------------------------------------
#   Download jq 
#	TBD - boto currently supports filtering. Could do away with jq
# ------------------------------------------------------------------

wget https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 -O jq
chmod 755 ./jq | tee -a ${HANA_LOG_FILE}
cd -

# ------------------------------------------------------------------
#          Get any advanced option JSON input (if any)
# ------------------------------------------------------------------


log `date` END install-aws

if [ -z "${HANA_LOG_FILE}" ] ; then
    HANA_LOG_FILE=${SCRIPT_DIR}/install.log
fi

log 'Dowloading AdvancedOptions JSON Start'
${PYTHON_BIN} ${SCRIPT_DIR}/get_advancedoptions.py  -o ${SCRIPT_DIR} >> ${HANA_LOG_FILE}
log 'Dowloading AdvancedOptions JSON End'


# export advanced options
[ -e /root/install/config.sh ] && source /root/install/config.sh

# ------------------------------------------------------------------
#          If debug is enabled, ALWAYS signal early SUCCESS
#          This allows customer to be able to SSH and debug
# ------------------------------------------------------------------


if [ "${DEBUG_DEPLOYMENT}" -eq "True" ]; then
    sh /root/install/signal-complete.sh
fi

exit 0








