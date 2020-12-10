#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds packet setup command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

# Run Ansible playbook
cd
cat > packet-setup.yaml <<-EOF
- name: setup Packet host
  hosts: localhost
  collections:
   - community.general
  gather_facts: no
  vars:
    - cluster_type: "{{ lookup('env', 'CLUSTER_TYPE') }}"
    - slackhook_path: "{{ lookup('env', 'CLUSTER_PROFILE_DIR') }}"
  vars_files:
    - "{{ lookup('env', 'CLUSTER_PROFILE_DIR') }}/.packet-kni-vars"

  tasks:

  - name: check cluster type
    fail:
      msg: "Unsupported CLUSTER_TYPE '{{ cluster_type }}'"
    when: cluster_type != "packet"

  - name: create Packet host with error handling
    block:
    - name: create Packet host {{ packet_hostname }}
      packet_device:
        auth_token: "{{ packet_auth_token }}"
        project_id: "{{ packet_project_id }}"
        hostnames: "{{ packet_hostname }}"
        operating_system: centos_8
        plan: m2.xlarge.x86
        facility: any
        wait_for_public_IPv: 4
        state: active
        tags: "{{ 'PR:', lookup('env', 'PULL_NUMBER'), 'Job name:', lookup('env', 'JOB_NAME'), 'Job id:', lookup('env', 'PROW_JOB_ID') }}"
      register: hosts
      no_log: true
    - name: wait for ssh
      wait_for:
        delay: 5
        host: "{{ hosts.devices[0].public_ipv4 }}"
        port: 22
        state: started
        timeout: 900
    rescue:
    - name: Send notification message via Slack in case of failure
      slack:
        token: "{{ 'T027F3GAJ/B011TAG710V/' + lookup('file', slackhook_path + '/.slackhook') }}"
        msg: "Packet setup failed. Error msg: {{ ansible_failed_result.msg }}"
        username: "{{ packet_hostname }}"
        color: warning
        icon_emoji: ":failed:"
    - name: fail the play
      fail:
        msg: "ERROR: Packet setup failed."

  - name: save Packet IP
    local_action: copy content="{{ hosts.devices[0].public_ipv4 }}" dest="{{ lookup('env', 'SHARED_DIR') }}/server-ip"
EOF

ansible-playbook packet-setup.yaml -e "packet_hostname=ipi-${NAMESPACE}-${JOB_NAME_HASH}-${BUILD_ID}"

# Fetch packet server IP
IP=$(cat "${SHARED_DIR}/server-ip")
SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -i "${CLUSTER_PROFILE_DIR}/.packet-kni-ssh-privatekey")

# Checkout packet server
for x in $(seq 10) ; do
    test "$x" -eq 10 && exit 1
    ssh "${SSHOPTS[@]}" "root@${IP}" hostname && break
    sleep 10
done

scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:pull-secret"

timeout -s 9 5m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF

set -xeuo pipefail

# NVMe makes it faster
NVME_DEVICE="/dev/nvme0n1"
WORKING_DIR="/opt/${JOB_NAME}"
if [ -e "\${NVME_DEVICE}" ];
then
  mkfs.xfs -f "\${NVME_DEVICE}"
  mkdir -p "\${WORKING_DIR}"
  mount "\${NVME_DEVICE}" "\${WORKING_DIR}"
fi

echo "export WORKING_DIR='\${WORKING_DIR}'" >> /root/packet_config

EOF