#!/bin/bash
# run-ansible.sh - Helper script to run Ansible playbooks
#
# Usage: ./run-ansible.sh <playbook> [ansible-playbook args...]
#
# Examples:
#   ./run-ansible.sh playbooks/collect_manifests.yml
#   ./run-ansible.sh playbooks/patch_monthly_security.yml --limit rhel9_hosts
#   ./run-ansible.sh playbooks/stig_harden_internal_vm.yml --tags rsyslog

set -euo pipefail

CONTAINER_NAME="airgap-ansible-control"
RUNNER_PATH="/runner/project"

usage() {
    cat << EOF
Usage: $(basename "$0") <playbook> [ansible-playbook args...]

Run Ansible playbooks via the ansible-control container.

Arguments:
    playbook    Path to playbook (relative to project root)
                Examples: playbooks/collect_manifests.yml
                         playbooks/patch_monthly_security.yml

Options:
    Any additional arguments are passed to ansible-playbook.

Examples:
    $(basename "$0") playbooks/collect_manifests.yml
    $(basename "$0") playbooks/patch_monthly_security.yml --limit rhel9_hosts
    $(basename "$0") playbooks/stig_harden_internal_vm.yml --tags rsyslog -v
    $(basename "$0") playbooks/bootstrap_ssh_keys.yml -k

Available playbooks:
    - playbooks/bootstrap_ssh_keys.yml      Deploy SSH keys (use -k first time)
    - playbooks/configure_internal_repo.yml Configure repo clients
    - playbooks/collect_manifests.yml       Collect package manifests
    - playbooks/patch_monthly_security.yml  Apply security updates
    - playbooks/stig_harden_internal_vm.yml STIG hardening with syslog TLS
    - playbooks/site.yml                    Full site playbook
EOF
    exit 1
}

# Check arguments
if [[ $# -lt 1 ]]; then
    usage
fi

PLAYBOOK="$1"
shift

# Check if container is running
if ! podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Error: Container '${CONTAINER_NAME}' is not running."
    echo "Start it with: systemctl --user start airgap-ansible-control"
    exit 1
fi

# Run ansible-playbook in container
echo "Running: ansible-playbook ${RUNNER_PATH}/${PLAYBOOK} $*"
echo "---"

exec podman exec -it "${CONTAINER_NAME}" \
    ansible-playbook "${RUNNER_PATH}/${PLAYBOOK}" "$@"
