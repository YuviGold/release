#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts setup command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

# Fetch packet server IP
IP=$(cat "${SHARED_DIR}/server-ip")

SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -i "${CLUSTER_PROFILE_DIR}/.packet-kni-ssh-privatekey")

# Checkout dev-scripts and make
for x in $(seq 10) ; do
    test "$x" -eq 10 && exit 1
    ssh "${SSHOPTS[@]}" "root@${IP}" hostname && break
    sleep 10
done

# Get dev-scripts logs
finished()
{
  set +e

  # Get dev-scripts logs
  echo "dev-scripts setup completed, fetching logs"
  ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - \${WORKING_DIR}/logs | tar -C "${ARTIFACT_DIR}" -xzf -
  sed -i -e 's/.*auths.*/*** PULL_SECRET ***/g' "${ARTIFACT_DIR}"\${WORKING_DIR}/logs/*
}
trap finished EXIT TERM

# Copy dev-scripts source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/dev-scripts.tar.gz"

# Additional mechanism to inject dev-scripts additional variables directly 
# from a multistage step configuration.
# Backward compatible with the previous approach based on creating the
# dev-scripts-additional-config file from a multistage step command
if [[ -n "${DEVSCRIPTS_CONFIG:-}" ]]; then
  readarray -t config <<< "${DEVSCRIPTS_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then 
      echo "export ${var}" >> "${SHARED_DIR}/dev-scripts-additional-config"
    fi
  done
fi

# Copy additional dev-script configuration provided by the the job, if present
if [[ -e "${SHARED_DIR}/dev-scripts-additional-config" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/dev-scripts-additional-config" "root@${IP}:dev-scripts-additional-config"
fi

timeout -s 9 175m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeuo pipefail

yum install -y git sysstat sos
systemctl start sysstat

mkdir -p /tmp/artifacts

source /root/packet_config

tar -xzvf dev-scripts.tar.gz -C "\${WORKING_DIR}"
chown -R root:root "\${WORKING_DIR}"

cd "\${WORKING_DIR}"

cp /root/pull-secret \${WORKING_DIR}/pull_secret.json

echo "export OPENSHIFT_RELEASE_IMAGE=${OPENSHIFT_INSTALL_RELEASE_IMAGE}" >> \${WORKING_DIR}/config_root.sh
echo "export ADDN_DNS=\$(awk '/nameserver/ { print \$2;exit; }' /etc/resolv.conf)" >> \${WORKING_DIR}/config_root.sh
echo "export OPENSHIFT_CI=true" >> \${WORKING_DIR}/config_root.sh
echo "export WORKER_MEMORY=16384" >> \${WORKING_DIR}/config_root.sh

# Inject PR additional configuration, if available
if [[ -e \${WORKING_DIR}/dev-scripts-additional-config ]]
then
  cat \${WORKING_DIR}/dev-scripts-additional-config >> \${WORKING_DIR}/config_root.sh
# Inject job additional configuration, if available
elif [[ -e /root/dev-scripts-additional-config ]]
then
  cat /root/dev-scripts-additional-config >> \${WORKING_DIR}/config_root.sh
fi

echo 'export KUBECONFIG=\${WORKING_DIR}/ocp/ostest/auth/kubeconfig' >> /root/.bashrc

timeout -s 9 105m make

EOF
