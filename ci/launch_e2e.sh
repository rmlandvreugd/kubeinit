#!/bin/bash
set -e

#############################################################################
#                                                                           #
# Copyright kubeinit contributors.                                          #
#                                                                           #
# Licensed under the Apache License, Version 2.0 (the "License"); you may   #
# not use this file except in compliance with the License. You may obtain   #
# a copy of the License at:                                                 #
#                                                                           #
# http://www.apache.org/licenses/LICENSE-2.0                                #
#                                                                           #
# Unless required by applicable law or agreed to in writing, software       #
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT #
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the  #
# License for the specific language governing permissions and limitations   #
# under the License.                                                        #
#                                                                           #
#############################################################################

echo "(launch_e2e.sh) ==> Executing run.sh ..."

REPOSITORY="${1}"
BRANCH_NAME="${2}"
PULL_REQUEST="${3}"
DISTRO="${4}"
DRIVER="${5}"
MASTERS="${6}"
WORKERS="${7}"
HYPERVISORS="${8}"
JOB_TYPE="${9}"
LAUNCH_FROM="${10}"

KUBEINIT_SPEC="${DISTRO}-${DRIVER}-${MASTERS}-${WORKERS}-${HYPERVISORS}-${LAUNCH_FROM}"

KUBEINIT_ANSIBLE_VERBOSITY="${GH_ANSIBLE_VERBOSITY:=v}"

KUBEINIT_MAIN_CI_REPOSITORY="https://github.com/kubeinit/kubeinit.git"

if [[ "$REPOSITORY" == "kubeinit/kubeinit" ]]; then
    REPOSITORY="${KUBEINIT_MAIN_CI_REPOSITORY}"
fi

if [ -f /etc/redhat-release ]; then
    OS_VERSION=$(cat /etc/redhat-release)
elif [ -f /etc/fedora-release ]; then
    OS_VERSION=$(cat /etc/fedora-release)
elif [ -f /etc/lsb-release ]; then
    source /etc/lsb-release
    OS_VERSION=${DISTRIB_DESCRIPTION}
elif [ -f /etc/debian_version ]; then
    OS_VERSION="Debian $(cat /etc/debian_version)"
else
    OS_VERSION="Unknown"
fi
OS_VERSION="${OS_VERSION} - $(uname -a)"

#
# For the multinode deployment we only support a 2 nodes cluster
#
if [[ "$HYPERVISORS" != "1" && "$HYPERVISORS" != "2" ]]; then
    echo "(launch_e2e.sh) ==> We only support 1 and 2 nodes clusters"
    exit 1
fi

echo "(launch_e2e.sh) ==> Hosts OS $OS_VERSION"
echo "(launch_e2e.sh) ==> The repository is $REPOSITORY"
echo "(launch_e2e.sh) ==> The branch is $BRANCH_NAME"
echo "(launch_e2e.sh) ==> The pull request is $PULL_REQUEST"
echo "(launch_e2e.sh) ==> The distro is $DISTRO"
echo "(launch_e2e.sh) ==> The driver is $DRIVER"
echo "(launch_e2e.sh) ==> The amount of master nodes is $MASTERS"
echo "(launch_e2e.sh) ==> The amount of worker nodes is $WORKERS"
echo "(launch_e2e.sh) ==> The amount of hypervisors is $HYPERVISORS"
echo "(launch_e2e.sh) ==> The job type is $JOB_TYPE"
echo "(launch_e2e.sh) ==> The ansible will be launched from $LAUNCH_FROM"
echo "(launch_e2e.sh) ==> The ansible verbosity is $KUBEINIT_ANSIBLE_VERBOSITY"

echo "(launch_e2e.sh) ==> Removing old tmp files ..."
rm -rf tmp
mkdir -p tmp
cd tmp

echo "(launch_e2e.sh) ==> Downloading KubeInit's code ..."
# Get the kubeinit code we will test
if [[ "$JOB_TYPE" == "pr" ]]; then
    DEST_BRANCH=$(curl --silent "https://api.github.com/repos/kubeinit/kubeinit/pulls" | jq -c ".[] | select( .number | contains(${PULL_REQUEST})) | .base | .label" | tr -d \" | cut -d':' -f2)

    # Keep as an example for cherry-picking workarounds
    # git remote add ccamacho https://github.com/ccamacho/kubeinit.git
    # git fetch ccamacho
    # git cherry-pick 58f718a29d5611234304b1e144a69
    git clone -n $REPOSITORY -b $BRANCH_NAME
    cd kubeinit
    git fetch origin pull/$PULL_REQUEST/head
    git checkout -b pr  FETCH_HEAD
    git remote add upstream https://github.com/kubeinit/kubeinit.git
    git fetch upstream
    git rebase upstream/${DEST_BRANCH}
    git log -n 5 --pretty=oneline
else
    git clone $REPOSITORY
    cd kubeinit
    git checkout $BRANCH_NAME
fi

# Install the collection
echo "(launch_e2e.sh) ==> Installing KubeInit ..."
cd kubeinit
rm -rf ~/.ansible/collections/ansible_collections/kubeinit/kubeinit
ansible-galaxy collection build -v --force --output-path releases/
ansible-galaxy collection install --force --force-with-deps releases/kubeinit-kubeinit-`cat galaxy.yml | shyaml get-value version`.tar.gz
cd ..

#
# Begin ARA configuration
#

podman pod kill ara-pod || true
podman pod stop ara-pod || true
podman pod rm ara-pod || true

podman pod create \
    --name ara-pod \
    --publish 26973:8000

#
# When the playbook is executed from a container
# the callback plugin is not able to write back the
# data to the api client, we need to make explicit
# that information as environment variables when
# running the deployment containers.
#

echo "(launch_e2e.sh) ==> Preparing API server container ..."
rm -rf ~/.ara/server || true
rm -rf ~/.ara/output_data || true
mkdir -p ~/.ara/server
mkdir -p ~/.ara/output_data

# The port redirection is at pod level
# we redirect the 26973:8000 as the api server
# listens in the 8000 port
podman run --name api-server \
            --pod ara-pod \
            --detach --tty \
            --volume ~/.ara/server:/opt/ara:z \
            --volume ~/.ara/output_data:/opt/output_data:z \
            docker.io/recordsansible/ara-api:latest

#
# Any change in the way the logs from Ansible are
# gathered needs to be tested in both scenarios, when
# we launch the playbook from the host and from a container
#

echo "(launch_e2e.sh) ==> Allow queries from anywhere and restart the api-server container ..."
until [ -f ~/.ara/server/settings.yaml ]; do
    sleep 5
done

# If we need to make changes to the ara api container
# we can update the settings.yaml file and restart the container
# sed -i "s/  - ::1/  - '*'/" ~/.ara/server/settings.yaml
# podman restart api-server

echo "(launch_e2e.sh) ==> Configuring ara callback ..."
export ANSIBLE_CALLBACK_PLUGINS="$(python3 -m ara.setup.callback_plugins)"
# The action plugins variable is required to be able to record
export ANSIBLE_ACTION_PLUGINS="$(python3 -m ara.setup.action_plugins)"
export ANSIBLE_LOAD_CALLBACK_PLUGINS=true
export ARA_API_CLIENT="http"
export ARA_API_SERVER="http://127.0.0.1:26973"

podman exec -it api-server /bin/bash -c "ara-manage migrate"
#
# End ARA configuration
#

# #
# # Adjust the inventory
# #
# # This is dinamically alocated based on the spec string
# if [[ "$HYPERVISORS" == "2" ]]; then
#     # We enable the other HV
#     sed -i -e "/# hypervisor-02 ansible_host=tyto/ s/# //g" kubeinit/inventory
# fi

#
# Install the CLI/agent
#
python3 -m pip install -r ./agent/requirements.txt
KUBEINIT_REVISION="${revision:-ci}" python3 -m pip install --upgrade ./agent

#
# Check if this is a multicluster deployment
# this means that the distro has a period in
# the name like okd.rke, k8s.rke, or k8s.eks
#
if [[ $DISTRO == *.* ]] ; then
    FIRST_DISTRO="$(cut -d'.' -f1 <<<"${DISTRO}")"
    SECOND_DISTRO="$(cut -d'.' -f2 <<<"${DISTRO}")"
    FIRST_KUBEINIT_SPEC="${KUBEINIT_SPEC/${DISTRO}/${FIRST_DISTRO}}"
    SECOND_KUBEINIT_SPEC="${KUBEINIT_SPEC/${DISTRO}/${SECOND_DISTRO}}"
    KUBEINIT_SPEC="${FIRST_KUBEINIT_SPEC},${SECOND_KUBEINIT_SPEC}"

    # We will enable only submariner in the
    # case of having a multicluster deployment
    # for okd.rke
    if [[ "$DISTRO" == "okd.rke" ]]; then
        # TODO:FIXME: Submariner might be configured like
        # submariner=broker or submariner=secondary
        POST_DEPLOYMENT_SERVICES='submariner'
    # We enable two cluster ids in the inventory for both the cluster name and the network
    sed -i -e "/# cluster0/ s/# cluster0/${FIRST_DISTRO}cluster/" kubeinit/inventory
    sed -i -e "/# cluster1/ s/# cluster1/${SECOND_DISTRO}cluster/" kubeinit/inventory
    sed -i -e "/# kimgtnet/ s/# kimgtnet/kimgtnet/" kubeinit/inventory
    fi
fi

echo "(launch_e2e.sh) ==> The inventory content..."
cat ./kubeinit/inventory || true

#
# Create aux file with environment information
#

kubeinit -b > ./kubeinit/aux_info_file.txt
echo "" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> Hosts OS: ${OS_VERSION}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> Date: $(date +"%Y.%m.%d.%H.%M.%S")" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> Kubeinit agent/cli version: $(kubeinit -v) " >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The repository is: ${REPOSITORY}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The branch is: ${BRANCH_NAME}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The pull request is: ${PULL_REQUEST}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The distro is: ${DISTRO}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The driver is: ${DRIVER}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The amount of master nodes is: ${MASTERS}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The amount of worker nodes is: ${WORKERS}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The amount of hypervisors is: ${HYPERVISORS}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The job type is: ${JOB_TYPE}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The ansible deployment will be launched from: ${LAUNCH_FROM}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The ansible verbosity level is: ${KUBEINIT_ANSIBLE_VERBOSITY}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The job URL: ${CI_JOB_URL}" >> ./kubeinit/aux_info_file.txt
echo "(launch_e2e.sh) ==> The kubeinit spec string is: ${KUBEINIT_SPEC}" >> ./kubeinit/aux_info_file.txt

#
# This logic allows to record specific files or content before starting
# the deployment, we add this at the beginning of the deployment
# because if there is a runtime error then these tasks might not
# run at all. We also do this before choosing if the deployment is
# containerized or not.
#

echo "(launch_e2e.sh) ==> Running record tasks ..."
tee ./playbook_tmp.yml << endoffile
---
- name: Record useful files and variables to the deployment
  hosts: localhost
  tasks:
    # Relative to the kubeinit folder
    - name: Record deployment extra information
      ara_record:
        key: extra_information
        value: "{{ lookup('file', './aux_info_file.txt') }}"
        type: text

    - name: Record host file
      ara_record:
        key: inventory
        value: "{{ lookup('file', './inventory') }}"
        type: text

endoffile

# This will concatenate to the deployment playbook
# the initial ARA playbook to record some details
# related to the deployment
sed -i 's/---//g' ./kubeinit/playbook.yml
cat ./kubeinit/playbook.yml >> ./playbook_tmp.yml
mv ./playbook_tmp.yml ./kubeinit/playbook.yml

#
# The last step is to run the deployment
#
echo "(launch_e2e.sh) ==> Deploying the cluster ..."

#
# The deployment playbook can be launched from a container [c]
# or directly from the host [h]
#

FAILED="0"
KUBEINIT_SPEC=${KUBEINIT_SPEC//,/$'\n'}

if [[ "$LAUNCH_FROM" == "h" ]]; then
    {
        for SPEC in $KUBEINIT_SPEC; do
            echo "(launch_e2e.sh) ==> Deploying ${SPEC}"
            CLUSTER_NAME="$(cut -d'-' -f1 <<<"${SPEC}")"
            ansible-playbook \
                --user root \
                -${KUBEINIT_ANSIBLE_VERBOSITY:=v} \
                -i ./kubeinit/inventory \
                -e kubeinit_inventory_cluster_name=${CLUSTER_NAME}cluster \
                -e kubeinit_inventory_post_deployment_services="${POST_DEPLOYMENT_SERVICES:-none}" \
                -e kubeinit_spec=${SPEC} \
                ./kubeinit/playbook.yml
        done
    } || {
        echo "(launch_e2e.sh) ==> The deployment failed, we still need to run the cleanup tasks"
        FAILED="1"
    }

    if [[ "$JOB_TYPE" == "pr" ]]; then
        #
        # This while true will provide the feature of adding the label 'waitfordebug'
        # to any PR in the main repository, if this label is found, then we will wait for
        # 10 minutes until the label is removed from the pull request, after the label is
        # removed the cleanup tasks will be executed.
        #
        while true; do
            waitfordebug=$(curl \
                            --silent \
                            --location \
                            --request GET "https://api.github.com/repos/kubeinit/kubeinit/issues/${PULL_REQUEST}/labels" | \
                            jq -c '.[] | select(.name | contains("waitfordebug")).name' | tr -d '"')
            if [ "$waitfordebug" == "waitfordebug" ]; then
                echo "Wait for debugging the environment for 10 minutes"
                sleep 600
            else
                break
            fi
        done
    fi

    for SPEC in $KUBEINIT_SPEC; do
        echo "(launch_e2e.sh) ==> Cleaning ${SPEC}"
        CLUSTER_NAME="$(cut -d'-' -f1 <<<"${SPEC}")"
        ansible-playbook \
            --user root \
            -${KUBEINIT_ANSIBLE_VERBOSITY:=v} \
            -i ./kubeinit/inventory \
            -e kubeinit_inventory_cluster_name=${CLUSTER_NAME}cluster \
            -e kubeinit_inventory_post_deployment_services="${POST_DEPLOYMENT_SERVICES:-none}" \
            -e kubeinit_spec=${SPEC} \
            -e kubeinit_stop_after_task=task-cleanup-hypervisors \
            ./kubeinit/playbook.yml
    done
else
    echo "(launch_e2e.sh) ==> The parameter launch from do not match a valid value [c|h]"
    exit 1
fi
if [[ "$FAILED" == "1" ]]; then
    echo "(launch_e2e.sh) ==> The deployment command failed, this script must fail"
    exit 1
fi
