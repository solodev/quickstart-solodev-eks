#!/bin/bash -e
# Bastion Bootstrapping
# authors: tonynv@amazon.com, sancard@amazon.com, ianhill@amazon.com
# NOTE: This requires GNU getopt. On Mac OS X and FreeBSD you must install GNU getopt and mod the checkos function so that it's supported


# Configuration
PROGRAM='Linux Bastion'

##################################### Functions Definitions

function checkos () {
    platform='unknown'
    unamestr=`uname`
    if [[ "${unamestr}" == 'Linux' ]]; then
        platform='linux'
    else
        echo "[WARNING] This script is not supported on MacOS or FreeBSD"
        exit 1
    fi
    echo "${FUNCNAME[0]} Ended"
}

function retry_command() {
    local -r __tries="$1"; shift
    local -r __run="$@"
    local -i __backoff_delay=2

    until $__run
        do
                if (( __current_try == __tries ))
                then
                        echo "Tried $__current_try times and failed!"
                        return 1
                else
                        echo "Retrying ...."
                        sleep $((((__backoff_delay++)) + ((__current_try++))))
                fi
        done

}

function setup_environment_variables() {
    REGION=$(curl -sq http://169.254.169.254/latest/meta-data/placement/availability-zone/)
      #ex: us-east-1a => us-east-1
    REGION=${REGION: :-1}

    ETH0_MAC=$(/sbin/ip link show dev eth0 | /bin/egrep -o -i 'link/ether\ ([0-9a-z]{2}:){5}[0-9a-z]{2}' | /bin/sed -e 's,link/ether\ ,,g')

    _userdata_file="/var/lib/cloud/instance/user-data.txt"

    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    EIP_LIST=$(grep EIP_LIST ${_userdata_file} | sed -e 's/EIP_LIST=//g' -e 's/\"//g')

    LOCAL_IP_ADDRESS=$(curl -sq 169.254.169.254/latest/meta-data/network/interfaces/macs/${ETH0_MAC}/local-ipv4s/)

    CWG=$(grep CLOUDWATCHGROUP ${_userdata_file} | sed 's/CLOUDWATCHGROUP=//g')

    # LOGGING CONFIGURATION
    BASTION_MNT="/var/log/bastion"
    BASTION_LOG="bastion.log"
    echo "Setting up bastion session log in ${BASTION_MNT}/${BASTION_LOG}"
    mkdir -p ${BASTION_MNT}
    BASTION_LOGFILE="${BASTION_MNT}/${BASTION_LOG}"
    BASTION_LOGFILE_SHADOW="${BASTION_MNT}/.${BASTION_LOG}"
    touch ${BASTION_LOGFILE}
    if ! [ -L "$BASTION_LOGFILE_SHADOW" ]; then
      ln ${BASTION_LOGFILE} ${BASTION_LOGFILE_SHADOW}
    fi
    mkdir -p /usr/bin/bastion
    touch /tmp/messages
    chmod 770 /tmp/messages

    export REGION ETH0_MAC EIP_LIST CWG BASTION_MNT BASTION_LOG BASTION_LOGFILE BASTION_LOGFILE_SHADOW \
          LOCAL_IP_ADDRESS INSTANCE_ID
}

function verify_dependencies(){
    if [[ "a$(which aws)" == "a" ]]; then
      pip install awscli
    fi
    echo "${FUNCNAME[0]} Ended"
}

function usage() {
    echo "$0 <usage>"
    echo " "
    echo "options:"
    echo -e "--help \t Show options for this script"
    echo -e "--banner \t Enable or Disable Bastion Message"
    echo -e "--enable \t SSH Banner"
    echo -e "--tcp-forwarding \t Enable or Disable TCP Forwarding"
    echo -e "--x11-forwarding \t Enable or Disable X11 Forwarding"
}

function chkstatus () {
    if [[ $? -eq 0 ]]
    then
        echo "Script [PASS]"
    else
        echo "Script [FAILED]" >&2
        exit 1
    fi
}

function osrelease () {
    OS=`cat /etc/os-release | grep '^NAME=' |  tr -d \" | sed 's/\n//g' | sed 's/NAME=//g'`
    if [[ "${OS}" == "Ubuntu" ]]; then
        echo "Ubuntu"
    elif [[ "${OS}" == "Amazon Linux AMI" ]] || [[ "${OS}" == "Amazon Linux" ]]; then
        echo "AMZN"
    elif [[ "${OS}" == "CentOS Linux" ]]; then
        echo "CentOS"
    elif [[ "${OS}" == "SLES" ]]; then
        echo "SLES"
    else
        echo "Operating System Not Found"
    fi
    echo "${FUNCNAME[0]} Ended" >> /var/log/cfn-init.log
}

function harden_ssh_security () {
    # Allow ec2-user only to access this folder and its content
    #chmod -R 770 /var/log/bastion
    #setfacl -Rdm other:0 /var/log/bastion

    # Make OpenSSH execute a custom script on logins
    echo -e "\nForceCommand /usr/bin/bastion/shell" >> /etc/ssh/sshd_config



cat <<'EOF' >> /usr/bin/bastion/shell
bastion_mnt="/var/log/bastion"
bastion_log="bastion.log"
# Check that the SSH client did not supply a command. Only SSH to instance should be allowed.
export Allow_SSH="ssh"
export Allow_SCP="scp"
if [[ -z $SSH_ORIGINAL_COMMAND ]] || [[ $SSH_ORIGINAL_COMMAND =~ ^$Allow_SSH ]] || [[ $SSH_ORIGINAL_COMMAND =~ ^$Allow_SCP ]]; then
#Allow ssh to instance and log connection
    if [[ -z "$SSH_ORIGINAL_COMMAND" ]]; then
        /bin/bash
        exit 0
    else
        $SSH_ORIGINAL_COMMAND
    fi
log_shadow_file_location="${bastion_mnt}/.${bastion_log}"
log_file=`echo "$log_shadow_file_location"`
DATE_TIME_WHOAMI="`whoami`:`date "+%Y-%m-%d %H:%M:%S"`"
LOG_ORIGINAL_COMMAND=`echo "$DATE_TIME_WHOAMI:$SSH_ORIGINAL_COMMAND"`
echo "$LOG_ORIGINAL_COMMAND" >> "${bastion_mnt}/${bastion_log}"
log_dir="/var/log/bastion/"

else
# The "script" program could be circumvented with some commands
# (e.g. bash, nc). Therefore, I intentionally prevent users
# from supplying commands.

echo "This bastion supports interactive sessions only. Do not supply a command"
exit 1
fi
EOF

    # Make the custom script executable
    chmod a+x /usr/bin/bastion/shell

    release=$(osrelease)
    if [[ "${release}" == "CentOS" ]]; then
        semanage fcontext -a -t ssh_exec_t /usr/bin/bastion/shell
    fi

    echo "${FUNCNAME[0]} Ended"
}

function setup_logs () {

    echo "${FUNCNAME[0]} Started"

    if [[ "${release}" == "SLES" ]]; then
        curl 'https://s3.amazonaws.com/amazoncloudwatch-agent/suse/amd64/latest/amazon-cloudwatch-agent.rpm' -O
        zypper install --allow-unsigned-rpm -y ./amazon-cloudwatch-agent.rpm
        rm ./amazon-cloudwatch-agent.rpm
    elif [[ "${release}" == "CentOS" ]]; then
        curl 'https://s3.amazonaws.com/amazoncloudwatch-agent/centos/amd64/latest/amazon-cloudwatch-agent.rpm' -O
        rpm -U ./amazon-cloudwatch-agent.rpm
        rm ./amazon-cloudwatch-agent.rpm
    elif [[ "${release}" == "Ubuntu" ]]; then
        curl 'https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb' -O
        dpkg -i -E ./amazon-cloudwatch-agent.deb
        rm ./amazon-cloudwatch-agent.deb
    elif [[ "${release}" == "AMZN" ]]; then
        curl 'https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm' -O
        rpm -U ./amazon-cloudwatch-agent.rpm
        rm ./amazon-cloudwatch-agent.rpm
    fi

    cat <<EOF >> /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
    "logs": {
        "force_flush_interval": 5,
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "${BASTION_LOGFILE_SHADOW}",
                        "log_group_name": "${CWG}",
                        "log_stream_name": "{instance_id}",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S",
                        "timezone": "UTC"
                    }
                ]
            }
        }
    }
}
EOF

    if [ -x /bin/systemctl ] || [ -x /usr/bin/systemctl ]; then
        systemctl enable amazon-cloudwatch-agent.service
        systemctl restart amazon-cloudwatch-agent.service
    else
        start amazon-cloudwatch-agent
    fi
}

function setup_os () {

    echo "${FUNCNAME[0]} Started"

    if [[ "${release}" == "AMZN" ]] || [[ "${release}" == "CentOS" ]]; then
        bash_file="/etc/bashrc"
    else
        bash_file="/etc/bash.bashrc"
    fi

cat <<EOF >> "${bash_file}"
#Added by Linux bastion bootstrap
declare -rx IP=\$(echo \$SSH_CLIENT | awk '{print \$1}')
declare -rx BASTION_LOG=${BASTION_LOGFILE}
declare -rx PROMPT_COMMAND='history -a >(logger -t "[ON]:\$(date)   [FROM]:\${IP}   [USER]:\${USER}   [PWD]:\${PWD}" -s 2>>\${BASTION_LOG})'
EOF

    echo "Defaults env_keep += \"SSH_CLIENT\"" >> /etc/sudoers

    if [[ "${release}" == "Ubuntu" ]]; then
        user_group="ubuntu"
    elif [[ "${release}" == "CentOS" ]]; then
        user_group="centos"
    elif [[ "${release}" == "SLES" ]]; then
        user_group="users"
    else
        user_group="ec2-user"
    fi

    chown root:"${user_group}" "${BASTION_MNT}"
    chown root:"${user_group}" "${BASTION_LOGFILE}"
    chown root:"${user_group}" "${BASTION_LOGFILE_SHADOW}"
    chmod 662 "${BASTION_LOGFILE}"
    chmod 662 "${BASTION_LOGFILE_SHADOW}"
    chattr +a "${BASTION_LOGFILE}"
    chattr +a "${BASTION_LOGFILE_SHADOW}"
    touch /tmp/messages
    chown root:"${user_group}" /tmp/messages

    if [[ "${release}" == "CentOS" ]]; then
        restorecon -v /etc/ssh/sshd_config
        systemctl restart sshd
    fi

    if [[ "${release}" == "SLES" ]]; then
        zypper install --non-interactive bash-completion
        echo "0 0 * * * zypper patch --non-interactive" > ~/mycron
    elif [[ "${release}" == "Ubuntu" ]]; then
        apt-get install -y unattended-upgrades
        apt-get install -y bash-completion
        echo "0 0 * * * unattended-upgrades -d" > ~/mycron
    elif [[ "${release}" == "CentOS" ]]; then
        yum install -y bash-completion --enablerepo=epel
        echo "0 0 * * * yum -y update --security" > ~/mycron
    else
        echo "0 0 * * * yum -y update --security" > ~/mycron
    fi

    crontab ~/mycron
    rm ~/mycron

    echo "${FUNCNAME[0]} Ended"
}

function request_eip() {

    # Is the already-assigned Public IP an elastic IP?
    _query_assigned_public_ip

    set +e
    _determine_eip_assc_status ${PUBLIC_IP_ADDRESS}
    set -e

    if [[ ${_eip_associated} -eq 0 ]]; then
      echo "The Public IP address associated with eth0 (${PUBLIC_IP_ADDRESS}) is already an Elastic IP. Not proceeding further."
      exit 1
    fi

    EIP_ARRAY=(${EIP_LIST//,/ })
    _eip_assigned_count=0

    for eip in "${EIP_ARRAY[@]}"; do

      if [[ "${eip}" == "Null" ]]; then
        echo "Detected a NULL Value, moving on."
        continue
      fi

      # Determine if the EIP has already been assigned.
      set +e
      _determine_eip_assc_status ${eip}
      set -e
      if [[ ${_eip_associated} -eq 0 ]]; then
        echo "Elastic IP [${eip}] already has an association. Moving on."
        let _eip_assigned_count+=1
        if [[ "${_eip_assigned_count}" -eq "${#EIP_ARRAY[@]}" ]]; then
          echo "All of the stack EIPs have been assigned (${_eip_assigned_count}/${#EIP_ARRAY[@]}). I can't assign anything else. Exiting."
          exit 1
        fi
        continue
      fi

      _determine_eip_allocation ${eip}

      # Attempt to assign EIP to the ENI.
      set +e
      aws ec2 associate-address --instance-id ${INSTANCE_ID} --allocation-id  ${eip_allocation} --region ${REGION}

      rc=$?
      set -e

      if [[ ${rc} -ne 0 ]]; then

        let _eip_assigned_count+=1
        continue
      else
        echo "The newly-assigned EIP is ${eip}. It is mapped under EIP Allocation ${eip_allocation}"
        break
      fi
    done
    echo "${FUNCNAME[0]} Ended"
}

function _query_assigned_public_ip() {
  # Note: ETH0 Only.
  # - Does not distinguish between EIP and Standard IP. Need to cross-ref later.
  echo "Querying the assigned public IP"
  PUBLIC_IP_ADDRESS=$(curl -sq 169.254.169.254/latest/meta-data/public-ipv4/${ETH0_MAC}/public-ipv4s/)
}

function _determine_eip_assc_status(){
  # Is the provided EIP associated?
  # Also determines if an IP is an EIP.
  # 0 => true
  # 1 => false
  echo "Determining EIP Association Status for [${1}]"
  set +e
  aws ec2 describe-addresses --public-ips ${1} --output text --region ${REGION} 2>/dev/null  | grep -o -i eipassoc -q
  rc=$?
  set -e
  if [[ ${rc} -eq 1 ]]; then
    _eip_associated=1
  else
    _eip_associated=0
  fi

}

function _determine_eip_allocation(){
  echo "Determining EIP Allocation for [${1}]"
  resource_id_length=$(aws ec2 describe-addresses --public-ips ${1} --output text --region ${REGION} | head -n 1 | awk {'print $2'} | sed 's/.*eipalloc-//')
  if [[ "${#resource_id_length}" -eq 17 ]]; then
      eip_allocation=$(aws ec2 describe-addresses --public-ips ${1} --output text --region ${REGION}| egrep 'eipalloc-([a-z0-9]{17})' -o)
  else
      eip_allocation=$(aws ec2 describe-addresses --public-ips ${1} --output text --region ${REGION}| egrep 'eipalloc-([a-z0-9]{8})' -o)
  fi
}

function prevent_process_snooping() {
    # Prevent bastion host users from viewing processes owned by other users.
    mount -o remount,rw,hidepid=2 /proc
    awk '!/proc/' /etc/fstab > temp && mv temp /etc/fstab
    echo "proc /proc proc defaults,hidepid=2 0 0" >> /etc/fstab
    echo "${FUNCNAME[0]} Ended"
}

function setup_kubeconfig() {
    mkdir -p /home/${user_group}/.kube
    cat > /home/${user_group}/.kube/config <<EOF
apiVersion: v1
clusters:
- cluster:
    server: ${K8S_ENDPOINT}
    certificate-authority-data: ${K8S_CA_DATA}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: aws
  name: aws
current-context: aws
kind: Config
preferences: {}
users:
- name: aws
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      command: aws-iam-authenticator
      args:
        - "token"
        - "-i"
        - "${K8S_CLUSTER_NAME}"
        - "-r"
        - "${K8S_ROLE_ARN}"
EOF
    chown -R ${user_group} /home/${user_group}/.kube/
}

function install_kubernetes_client_tools() {
    echo "Installing Pip"
    easy_install pip
    echo "Upgrading AWS CLI"
    /usr/local/bin/pip3 install awscli --upgrade --user
    mkdir -p /usr/local/bin/
    echo "Install AWS IAM Auth"
    # retry_command 20 curl --retry 5 -o aws-iam-authenticator https://amazon-eks.s3-us-west-2.amazonaws.com/1.11.5/2018-12-06/bin/linux/amd64/aws-iam-authenticator
    retry_command 20 curl --retry 5 -o aws-iam-authenticator https://amazon-eks.s3-us-west-2.amazonaws.com/1.14.6/2019-08-22/bin/linux/amd64/aws-iam-authenticator
    chmod +x ./aws-iam-authenticator
    mv ./aws-iam-authenticator /usr/local/bin/
    echo "Install Kubectl"
    # retry_command 20 curl --retry 5 -o kubectl https://amazon-eks.s3-us-west-2.amazonaws.com/1.11.5/2018-12-06/bin/linux/amd64/kubectl
    retry_command 20 curl --retry 5 -o kubectl https://amazon-eks.s3-us-west-2.amazonaws.com/1.14.6/2019-08-22/bin/linux/amd64/kubectl
    chmod +x ./kubectl
    mv ./kubectl /usr/local/bin/
    echo "source <(/usr/local/bin/kubectl completion bash)" >> ~/.bashrc
    echo "Install Helm"
    retry_command 20 curl --retry 5 -o helm.tar.gz https://storage.googleapis.com/kubernetes-helm/helm-v2.12.2-linux-amd64.tar.gz
    tar -xvf helm.tar.gz
    chmod +x ./linux-amd64/helm
    chmod +x ./linux-amd64/tiller
    mv ./linux-amd64/helm /usr/local/bin/helm-client
    mv ./linux-amd64/tiller /usr/local/bin/
    rm -rf ./linux-amd64/
    touch /var/log/tiller.log
    chown ${user_group} /var/log/tiller.log
    cat > /usr/local/bin/helm <<"EOF"
#!/bin/bash
/usr/local/bin/tiller -listen 127.0.0.1:44134 -alsologtostderr -storage secret &>> /var/log/tiller.log &
# Give tiller a moment to come up
sleep 2
export HELM_HOST=127.0.0.1:44134
/usr/local/bin/helm-client "$@"
EXIT_CODE=$?
kill %1
exit ${EXIT_CODE}
EOF
    chmod +x /usr/local/bin/helm
    su ${user_group} -c "/usr/local/bin/helm init --client-only"
}

##################################### End Function Definitions

# Call checkos to ensure platform is Linux
checkos
# Verify dependencies are installed.
verify_dependencies
# Assuming it is, setup environment variables.
setup_environment_variables

## set an initial value
SSH_BANNER="LINUX BASTION"

# Read the options from cli input
TEMP=`getopt -o h --longoptions help,banner:,enable:,tcp-forwarding:,x11-forwarding: -n $0 -- "$@"`
eval set -- "${TEMP}"


if [[ $# == 1 ]] ; then echo "No input provided! type ($0 --help) to see usage help" >&2 ; exit 1 ; fi

# extract options and their arguments into variables.
while true; do
    case "$1" in
        -h | --help)
            usage
            exit 1
            ;;
        --banner)
            BANNER_PATH="$2";
            shift 2
            ;;
        --enable)
            ENABLE="$2";
            shift 2
            ;;
        --tcp-forwarding)
            TCP_FORWARDING="$2";
            shift 2
            ;;
        --x11-forwarding)
            X11_FORWARDING="$2";
            shift 2
            ;;
        --)
            break
            ;;
        *)
            break
            ;;
    esac
done

# BANNER CONFIGURATION
BANNER_FILE="/etc/ssh_banner"
if [[ ${ENABLE} == "true" ]];then
    if [[ -z ${BANNER_PATH} ]];then
        echo "BANNER_PATH is null skipping ..."
    else
        echo "BANNER_PATH = ${BANNER_PATH}"
        echo "Creating Banner in ${BANNER_FILE}"
        echo "curl  -s ${BANNER_PATH} > ${BANNER_FILE}"
        curl  -s ${BANNER_PATH} > ${BANNER_FILE}
        if [[ -e ${BANNER_FILE} ]] ;then
            echo "[INFO] Installing banner ... "
            echo -e "\n Banner ${BANNER_FILE}" >>/etc/ssh/sshd_config
        else
            echo "[INFO] banner file is not accessible skipping ..."
            exit 1;
        fi
    fi
else
    echo "Banner message is not enabled!"
fi

#Enable/Disable TCP forwarding
TCP_FORWARDING=`echo "${TCP_FORWARDING}" | sed 's/\\n//g'`

#Enable/Disable X11 forwarding
X11_FORWARDING=`echo "${X11_FORWARDING}" | sed 's/\\n//g'`

echo "Value of TCP_FORWARDING - ${TCP_FORWARDING}"
echo "Value of X11_FORWARDING - ${X11_FORWARDING}"
if [[ ${TCP_FORWARDING} == "false" ]];then
    awk '!/AllowTcpForwarding/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
    echo "AllowTcpForwarding no" >> /etc/ssh/sshd_config
    harden_ssh_security
fi

if [[ ${X11_FORWARDING} == "false" ]];then
    awk '!/X11Forwarding/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
    echo "X11Forwarding no" >> /etc/ssh/sshd_config
fi

release=$(osrelease)
if [[ "${release}" == "Operating System Not Found" ]]; then
    echo "[ERROR] Unsupported Linux Bastion OS"
    exit 1
else
    setup_os
    setup_logs
fi

prevent_process_snooping
request_eip
install_kubernetes_client_tools
setup_kubeconfig
KUBECONFIG="/home/${user_group}/.kube/config"
NAMESPACE="solodev-dcx"

su ${user_group} -c "/usr/local/bin/helm repo add charts 'https://raw.githubusercontent.com/techcto/charts/master/'"
su ${user_group} -c "/usr/local/bin/helm repo update"

#Network Setup
initCNI(){
    #WEAVE
    initWeave
}

initWeave(){
    echo "Install Weave CNI"
    curl --location -o ./weave-net.yaml "https://cloud.weave.works/k8s/net?k8s-version=$(/usr/local/bin/kubectl --kubeconfig $KUBECONFIG version | base64 | tr -d '\n')"
    /usr/local/bin/kubectl --kubeconfig $KUBECONFIG apply -f weave-net.yaml
}

initServiceAccount(){
    kubectl --kubeconfig=$KUBECONFIG create namespace solodev-dcx
    echo "aws eks describe-cluster --name ${K8S_CLUSTER_NAME} --region ${REGION} --query cluster.identity.oidc.issuer --output text"
    ISSUER_URL=$(aws eks describe-cluster --name ${K8S_CLUSTER_NAME} --region ${REGION} --query cluster.identity.oidc.issuer --output text )
    echo $ISSUER_URL
    ISSUER_URL_WITHOUT_PROTOCOL=$(echo $ISSUER_URL | sed 's/https:\/\///g' )
    ISSUER_HOSTPATH=$(echo $ISSUER_URL_WITHOUT_PROTOCOL | sed "s/\/id.*//" )
    rm *.crt || echo "No files that match *.crt exist"
    ROOT_CA_FILENAME=$(openssl s_client -showcerts -connect $ISSUER_HOSTPATH:443 < /dev/null \
                        | awk '/BEGIN/,/END/{ if(/BEGIN/){a++}; out="cert"a".crt"; print > out } END {print "cert"a".crt"}')
    ROOT_CA_FINGERPRINT=$(openssl x509 -fingerprint -noout -in $ROOT_CA_FILENAME \
                        | sed 's/://g' | sed 's/SHA1 Fingerprint=//')
    aws iam create-open-id-connect-provider \
                        --url $ISSUER_URL \
                        --thumbprint-list $ROOT_CA_FINGERPRINT \
                        --client-id-list sts.amazonaws.com \
                        --region ${REGION} || echo "A provider for $ISSUER_URL already exists"
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$ISSUER_URL_WITHOUT_PROTOCOL"
    cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {
            "Federated": "${PROVIDER_ARN}"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
            "StringEquals": {
                "${ISSUER_URL_WITHOUT_PROTOCOL}:sub": "system:serviceaccount:${NAMESPACE}:aws-serviceaccount"
            }
        }
    }]
}
EOF

    #To Review - AWS Marketplace Policy
    ROLE_NAME=solodev-usage-${K8S_CLUSTER_NAME}
    aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://trust-policy.json
    cat > iam-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "aws-marketplace:RegisterUsage"
            ],
            "Resource": "*",
            "Effect": "Allow"
        }
    ]
}
EOF

    POLICY_ARN=$(aws iam create-policy --policy-name AWSMarketplacePolicy-${K8S_CLUSTER_NAME} --policy-document file://iam-policy.json --query Policy.Arn | sed 's/"//g')
    echo ${POLICY_ARN}
    aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN
    echo $ROLE_NAME
    applyServiceAccount $ROLE_NAME
}

applyServiceAccount(){
    ROLE_NAME=$1
    echo "Role="$ROLE_NAME
    ROLE_ARN=$(aws iam get-role --role-name ${ROLE_NAME} --query Role.Arn --output text)
    /usr/local/bin/kubectl --kubeconfig $KUBECONFIG create sa aws-serviceaccount --namespace ${NAMESPACE}
    /usr/local/bin/kubectl --kubeconfig $KUBECONFIG annotate sa aws-serviceaccount eks.amazonaws.com/role-arn=$ROLE_ARN --namespace ${NAMESPACE}
    echo "Service Account Created: aws-serviceaccount"
}

initNetwork(){
    export PATH=/usr/local/bin/:$PATH
    su ${user_group} -c "/usr/local/bin/helm install --name nginx-ingress stable/nginx-ingress --set controller.service.annotations.\"service\.beta\.kubernetes\.io/aws-load-balancer-type\"=nlb \
        --set controller.publishService.enabled=true,controller.stats.enabled=true,controller.metrics.enabled=true,controller.hostNetwork=true,controller.kind=DaemonSet"
    su ${user_group} -c "/usr/local/bin/helm install --name external-dns stable/external-dns --set logLevel=debug \
        --set policy=sync --set domainFilters={${DOMAIN}} --set rbac.create=true \
        --set aws.zoneType=public --set txtOwnerId=${K8S_CLUSTER_NAME}"
        # --set controller.hostNetwork=true,controller.kind=DaemonSet"
}

initDashboard(){
    yum install -y jq
    DOWNLOAD_URL=$(curl --silent "https://api.github.com/repos/kubernetes-sigs/metrics-server/releases/latest" | jq -r .tarball_url)
    DOWNLOAD_VERSION=$(grep -o '[^/v]*$' <<< $DOWNLOAD_URL)
    curl -Ls $DOWNLOAD_URL -o metrics-server-$DOWNLOAD_VERSION.tar.gz
    mkdir metrics-server-$DOWNLOAD_VERSION
    tar -xzf metrics-server-$DOWNLOAD_VERSION.tar.gz --directory metrics-server-$DOWNLOAD_VERSION --strip-components 1
    /usr/local/bin/kubectl --kubeconfig $KUBECONFIG apply -f metrics-server-$DOWNLOAD_VERSION/deploy/1.8+/
    /usr/local/bin/kubectl --kubeconfig $KUBECONFIG get deployment metrics-server -n kube-system
    /usr/local/bin/kubectl --kubeconfig $KUBECONFIG apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta6/aio/deploy/alternative.yaml
    cat > eks-admin-service-account.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eks-admin
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: eks-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: eks-admin
  namespace: kube-system
EOF
    /usr/local/bin/kubectl --kubeconfig $KUBECONFIG apply -f eks-admin-service-account.yaml
    /usr/local/bin/kubectl --kubeconfig=$KUBECONFIG create clusterrolebinding permissive-binding --clusterrole=cluster-admin --user=admin --user=kubelet --group=system:serviceaccounts;
}

initStorage(){
    kubectl --kubeconfig=$KUBECONFIG apply -f https://raw.githubusercontent.com/techcto/charts/master/solodev-network/templates/storage-class.yaml
}

#Service Account
initServiceAccount

if [[ "$ProvisionSolodevDCXNetwork" = "Enabled" ]]; then
    initCNI
fi

initNetwork
initStorage

#Dashboard Setup
initDashboard

echo "Bootstrap complete."