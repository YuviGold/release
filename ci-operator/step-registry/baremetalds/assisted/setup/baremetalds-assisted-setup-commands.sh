#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted setup command ************"

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

# Fetch packet server IP
IP=$(cat "${SHARED_DIR}/server-ip")

SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -i "${CLUSTER_PROFILE_DIR}/.packet-kni-ssh-privatekey")

# Copy assisted source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted.tar.gz"

# Additional mechanism to inject assisted additional variables directly
# from a multistage step configuration.
# Backward compatible with the previous approach based on creating the
# assisted-additional-config file from a multistage step command
if [[ -n "${ASSISTED_CONFIG:-}" ]]; then
  readarray -t config <<< "${ASSISTED_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      echo "export ${var}" >> "${SHARED_DIR}/assisted-additional-config"
    fi
  done
fi

if [[ -e "${SHARED_DIR}/assisted-additional-config" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/assisted-additional-config" "root@${IP}:assisted-additional-config"
fi

timeout -s 9 175m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeuo pipefail

yum install -y git sysstat sos
systemctl start sysstat

mkdir -p /tmp/artifacts

source /root/packet_config

tar -xzvf assisted.tar.gz -C "\${WORKING_DIR}"
chown -R root:root "\${WORKING_DIR}"

cd "\${WORKING_DIR}"

set +x
echo "export PULL_SECRET='\$(cat /root/pull-secret)'" >> /root/config
echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST}" >> /root/config
echo "export PUBLIC_CONTAINER_REGISTRIES=quay.io,\$(echo ${RELEASE_IMAGE_LATEST} | cut -d'/' -f1)" >> /root/config
echo "export ASSISTED_SERVICE_HOST=${IP}" >> /root/config
set -x

if [[ -e /root/assisted-additional-config ]]
then
  cat /root/assisted-additional-config >> /root/config
fi

echo "export KUBECONFIG=\${WORKING_DIR}/build/kubeconfig" >> /root/.bashrc

source /root/config

timeout -s 9 105m make

EOF
