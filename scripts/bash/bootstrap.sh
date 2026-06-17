#!/usr/bin/env bash
# ============================================
# FortiGate Backup System - Bootstrap Script
# ============================================
# Complete setup of the backup infrastructure.
# Run this ONCE on the Ansible control node.
#
# Usage:
#   sudo ./bootstrap.sh
#   sudo ./bootstrap.sh --target /opt/fortigate-backup
#   sudo ./bootstrap.sh --skip-ansible
#   sudo ./bootstrap.sh --vault-password-file /etc/ansible/.vault_password
#
# WSL2 Usage (from Windows PowerShell):
#   .\scripts\powershell\bootstrap-wsl.ps1
#   .\scripts\powershell\manage.ps1 wsl-setup
# ============================================

set -euo pipefail

# ============================================
# WSL2 Detection
# ============================================
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
    echo "[WSL2] Detected: $(lsb_release -sd 2>/dev/null || echo 'unknown')"
fi

# ============================================
# Configuration
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET_DIR="${TARGET_DIR:-${PROJECT_ROOT}}"
ANSIBLE_DIR="${TARGET_DIR}/ansible"
SCRIPTS_DIR="${TARGET_DIR}/scripts"

# WSL2-aware paths
if [[ "$IS_WSL" == true ]]; then
    # In WSL2, store backups on Windows filesystem (persistent across distro resets)
    WIN_USERPROFILE=$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')" 2>/dev/null || echo "$HOME")
    LOG_DIR="${WIN_USERPROFILE}/fortigate-backups/logs"
    BACKUP_DIR="${WIN_USERPROFILE}/fortigate-backups/data"
else
    LOG_DIR="/var/log/fortigate-backup"
    BACKUP_DIR="/opt/backups/fortigates"
fi

DATA_DIR="${TARGET_DIR}/data"
VENV_DIR="${TARGET_DIR}/venv"
PYTHON_REQUIREMENTS="${TARGET_DIR}/requirements.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
# Helper Functions
# ============================================
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_command() {
    if ! command -v "$1" &>/dev/null; then
        log_error "Required command not found: $1"
        return 1
    fi
    log_ok "Found: $1 ($(command -v "$1"))"
}

check_root() {
    if [[ "$(id -u)" -ne 0 ]] && [[ "${SKIP_ROOT_CHECK:-false}" != "true" ]]; then
        log_error "This script must be run as root (or use --skip-root-check)"
        exit 1
    fi
    log_ok "Running with sufficient privileges"
}

# ============================================
# Installation Functions
# ============================================
install_system_dependencies() {
    log_info "Installing system dependencies..."

    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq \
            python3 python3-pip python3-venv \
            git ansible-core \
            openssh-client sshpass \
            curl wget jq tree \
            acl rsync \
            build-essential libssl-dev libffi-dev \
            ca-certificates gnupg lsb-release 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y \
            python3 python3-pip \
            git ansible-core \
            openssh-clients sshpass \
            curl wget jq tree \
            acl rsync \
            gcc openssl-devel libffi-devel \
            ca-certificates 2>/dev/null
    else
        log_warn "Unsupported package manager. Install dependencies manually."
    fi

    log_ok "System dependencies installed"
}

setup_python_environment() {
    log_info "Setting up Python virtual environment..."

    if [[ -d "${VENV_DIR}" ]]; then
        log_info "Virtual environment already exists, updating..."
    else
        python3 -m venv "${VENV_DIR}"
        log_ok "Virtual environment created at ${VENV_DIR}"
    fi

    source "${VENV_DIR}/bin/activate"
    pip install --upgrade pip setuptools wheel

    if [[ -f "${PYTHON_REQUIREMENTS}" ]]; then
        pip install -r "${PYTHON_REQUIREMENTS}"
        log_ok "Python packages installed from requirements.txt"
    else
        pip install \
            ansible-core \
            pyyaml jinja2 \
            requests paramiko \
            cryptography netaddr \
            prometheus-client
        log_ok "Core Python packages installed"
    fi

    # Install Ansible collections
    ansible-galaxy collection install \
        fortinet.fortios \
        community.network \
        community.general 2>/dev/null || true
    log_ok "Ansible collections installed"
}

setup_directories() {
    log_info "Setting up directory structure..."

    local directories=(
        "${BACKUP_DIR}"
        "${LOG_DIR}"
        "${DATA_DIR}"
        "${ANSIBLE_DIR}/playbooks"
        "${ANSIBLE_DIR}/roles"
        "${ANSIBLE_DIR}/inventory"
        "${ANSIBLE_DIR}/vault"
        "${ANSIBLE_DIR}/retrieved_files"
        "${SCRIPTS_DIR}/python"
        "${SCRIPTS_DIR}/bash"
        "${TARGET_DIR}/monitoring"
        "${TARGET_DIR}/security"
        "${TARGET_DIR}/ci_cd"
        "${TARGET_DIR}/docs"
        "${TARGET_DIR}/tests"
    )

    for dir in "${directories[@]}"; do
        mkdir -p "${dir}"
        log_ok "Created: ${dir}"
    done

    # Set permissions
    chmod 0750 "${BACKUP_DIR}"
    chmod 0750 "${DATA_DIR}"
    chmod 0700 "${ANSIBLE_DIR}/vault"

    log_ok "Directory structure created"
}

setup_logging() {
    log_info "Setting up logging infrastructure..."

    # Create logrotate configuration
    cat > /etc/logrotate.d/fortigate-backup << 'LOGROTATE'
/var/log/fortigate-backup/*.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl restart fortigate-backup-exporter 2>/dev/null || true
    endscript
}
LOGROTATE
    log_ok "Logrotate configuration created"
}

setup_ssh() {
    log_info "Setting up SSH keys and configuration..."

    local ssh_dir="${HOME}/.ssh"
    mkdir -p "${ssh_dir}"
    chmod 0700 "${ssh_dir}"

    # Generate backup-specific SSH key if not exists
    if [[ ! -f "${ssh_dir}/fortigate-backup-key" ]]; then
        ssh-keygen -t ed25519 -a 100 \
            -f "${ssh_dir}/fortigate-backup-key" \
            -C "fortigate-backup@$(hostname)" \
            -N "" 2>/dev/null
        log_ok "SSH key generated: ${ssh_dir}/fortigate-backup-key"
    else
        log_info "SSH key already exists"
    fi

    # Create SSH config for bastion/proxy
    cat > "${ssh_dir}/config" << 'SSHCONFIG'
# FortiGate Backup SSH Configuration
Host bastion
    HostName bastion.internal.local
    User backup-admin
    Port 22
    IdentityFile ~/.ssh/fortigate-backup-key
    ForwardAgent no
    ServerAliveInterval 30
    ServerAliveCountMax 3

Host 10.*.*.*
    ProxyJump bastion
    IdentityFile ~/.ssh/fortigate-backup-key
    User admin
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
    ServerAliveInterval 30
    ServerAliveCountMax 3
SSHCONFIG

    chmod 0600 "${ssh_dir}/config" "${ssh_dir}/fortigate-backup-key" 2>/dev/null || true
    log_ok "SSH configuration created"
}

setup_git() {
    log_info "Configuring git for backup repository..."

    git config --global user.name "FortiGate Backup System"
    git config --global user.email "backup-system@internal.local"
    git config --global core.sshCommand "ssh -i ${HOME}/.ssh/fortigate-backup-key"
    git config --global init.defaultBranch main

    # Initialize backup repository
    if [[ ! -d "${BACKUP_DIR}/.git" ]]; then
        cd "${BACKUP_DIR}"
        git init
        git checkout -b main
        log_ok "Git repository initialized at ${BACKUP_DIR}"
    else
        log_info "Git repository already exists"
    fi

    # Create .gitignore
    cat > "${BACKUP_DIR}/.gitignore" << 'GITIGNORE'
*.log
*.tmp
__pycache__/
.vault_password
*.pyc
GITIGNORE

    log_ok "Git configuration complete"
}

setup_git_crypt() {
    log_info "Setting up git-crypt..."

    if command -v git-crypt &>/dev/null; then
        cd "${BACKUP_DIR}"

        if [[ ! -f ".git-crypt" ]]; then
            git-crypt init
            log_ok "git-crypt initialized"
        else
            log_info "git-crypt already initialized"
        fi

        # Create .gitattributes for encrypted files
        cat > "${BACKUP_DIR}/.gitattributes" << 'GITATTRIBUTES'
*.key filter=git-crypt diff=git-crypt
*.pem filter=git-crypt diff=git-crypt
*.cert filter=git-crypt diff=git-crypt
*secret* filter=git-crypt diff=git-crypt
*password* filter=git-crypt diff=git-crypt
*vault* filter=git-crypt diff=git-crypt
GITATTRIBUTES

        log_ok "git-crypt configured with encrypted file patterns"
    else
        log_warn "git-crypt not installed. Install with: apt-get install git-crypt or brew install git-crypt"
    fi
}

setup_awx() {
    log_info "Creating AWX job template configuration..."

    local awx_config_dir="${PROJECT_ROOT}/ci_cd/awx"
    mkdir -p "${awx_config_dir}"

    # AWX job template spec
    cat > "${awx_config_dir}/backup-job-template.yml" << 'AWX'
---
# AWX Job Template for FortiGate Backup
# Import via awx-manage or AWX CLI
- name: "FortiGate - Full Backup"
  job_type: run
  inventory: "FortiGate Production"
  project: "FortiGate Backup System"
  playbook: "playbooks/backup.yml"
  credentials:
    - "FortiGate SSH Credential"
    - "Ansible Vault Password"
  execution_environment: "Default"
  forks: 50
  limit: ""
  verbosity: 1
  extra_vars:
    backup_method: "auto"
    notify_on_failure: true
  schedule:
    name: "Daily Backup at 02:00"
    rrule: "DTSTART:20250101T020000Z RRULE:FREQ=DAILY;INTERVAL=1"
  notification_templates:
    error: "Slack - Network Backups"
    success: "Slack - Network Backups"
AWX
    log_ok "AWX job template created"

    log_info ""
    log_info "To import AWX template:"
    log_info "  awx job_templates create --conf @ci_cd/awx/backup-job-template.yml"
}

setup_systemd_service() {
    log_info "Creating systemd service for backup exporter..."

    cat > /etc/systemd/system/fortigate-backup-exporter.service << 'SERVICE'
[Unit]
Description=FortiGate Backup Prometheus Exporter
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/opt/fortigate-backup/venv/bin/python3 /opt/fortigate-backup/scripts/python/health_check.py \
    --prometheus-output /var/lib/node_exporter/textfile/fortigate.prom \
    --backup-dir /opt/backups/fortigates
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

    cat > /etc/systemd/system/fortigate-backup-exporter.timer << 'TIMER'
[Unit]
Description=Run FortiGate Backup Exporter every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMER

    systemctl daemon-reload 2>/dev/null || true
    log_ok "Systemd service and timer created"
}

configure_firewall() {
    log_info "Configuring firewall rules..."

    if command -v ufw &>/dev/null; then
        ufw allow from 10.0.0.0/8 to any port 22 proto tcp comment 'SSH to FortiGates'
        ufw allow from 10.0.0.0/8 to any port 443 proto tcp comment 'HTTPS to FortiGates'
        log_ok "UFW rules configured"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.0.0/8" port port="22" protocol="tcp" accept'
        firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.0.0/8" port port="443" protocol="tcp" accept'
        firewall-cmd --reload
        log_ok "FirewallD rules configured"
    else
        log_warn "No firewall tool detected. Configure rules manually:"
        log_warn "  Allow SSH (22) and HTTPS (443) from management subnets"
    fi
}

create_ansible_vault() {
    log_info "Setting up Ansible Vault..."

    local vault_password_file="${ANSIBLE_DIR}/vault/.vault_password"

    if [[ ! -f "${vault_password_file}" ]]; then
        # Generate a secure random password
        openssl rand -base64 48 > "${vault_password_file}"
        chmod 0400 "${vault_password_file}"
        log_ok "Ansible Vault password generated: ${vault_password_file}"

        log_warn "IMPORTANT: Store this password securely!"
        log_warn "  Password: $(cat ${vault_password_file})"
    else
        log_info "Ansible Vault password already exists"
    fi

    # Create encrypted vault file template
    if [[ ! -f "${ANSIBLE_DIR}/vault/vault.yml" ]]; then
        cat > /tmp/vault_template.yml << 'VAULT'
# ============================================
# Ansible Vault - Encrypted Credentials
# ============================================
# Encrypt with:
#   ansible-vault encrypt ansible/vault/vault.yml
# ============================================

# FortiGate SSH credentials
vault_ansible_user: "backup-admin"
vault_ssh_key_path: "~/.ssh/fortigate-backup-key"

# FortiGate API credentials
vault_fortigate_api_user: "api-backup"
vault_fortigate_api_key: "CHANGE_ME_API_KEY"
vault_fortigate_validate_certs: false

# Network infrastructure
vault_bastion_host: "bastion.internal.local"
vault_bastion_user: "jump-admin"

# Notifications
vault_slack_webhook_url: "https://hooks.slack.com/services/CHANGE_ME"
vault_pagerduty_routing_key: "CHANGE_ME_PAGERDUTY_KEY"

# Syslog
vault_syslog_server: "10.150.0.30"

# Email (if using SMTP auth)
vault_smtp_server: "smtp.internal.local"
vault_smtp_port: 587
vault_smtp_user: "backup-notify@internal.local"
vault_smtp_password: "CHANGE_ME_SMTP_PASSWORD"
VAULT

        # Using ansible-vault encrypt
        ansible-vault encrypt \
            --vault-password-file "${vault_password_file}" \
            --output "${ANSIBLE_DIR}/vault/vault.yml" \
            /tmp/vault_template.yml 2>/dev/null || {
                mv /tmp/vault_template.yml "${ANSIBLE_DIR}/vault/vault.yml"
                log_warn "Created unencrypted vault template. Encrypt it:"
                log_warn "  ansible-vault encrypt ${ANSIBLE_DIR}/vault/vault.yml"
            }
        rm -f /tmp/vault_template.yml
        log_ok "Vault file created"
    fi
}

run_validation() {
    log_info "Running post-installation validation..."

    local errors=0

    # Validate Ansible configuration
    if [[ -f "${ANSIBLE_DIR}/ansible.cfg" ]]; then
        log_ok "Ansible config found"
    else
        log_error "Ansible config missing"
        ((errors++))
    fi

    # Validate inventory
    if [[ -f "${ANSIBLE_DIR}/inventory/production/hosts.yml" ]]; then
        log_ok "Production inventory found"
    else
        log_error "Production inventory missing"
        ((errors++))
    fi

    # Validate Python environment
    if [[ -f "${VENV_DIR}/bin/activate" ]]; then
        log_ok "Python virtual environment found"
    else
        log_error "Python virtual environment missing"
        ((errors++))
    fi

    # Validate ansible can parse inventory
    if source "${VENV_DIR}/bin/activate" && \
       ansible-inventory -i "${ANSIBLE_DIR}/inventory/production/hosts.yml" --list &>/dev/null; then
        log_ok "Ansible inventory parses correctly"
    else
        log_warn "Ansible inventory parsing warning"
    fi

    # Check connectivity to a test device
    log_info "Skipping device connectivity check (run manually: ansible all -m ping --limit fgt-sandbox-lab)"

    if [[ ${errors} -eq 0 ]]; then
        log_ok "All validations passed!"
    else
        log_warn "${errors} validation errors found - review above"
    fi
}

# ============================================
# Main Installation
# ============================================
main() {
    echo ""
    echo "============================================"
    echo " FortiGate Backup System - Bootstrap"
    echo "============================================"
    echo " Target: ${TARGET_DIR}"
    echo " Date:   $(date)"
    echo "============================================"
    echo ""

    # Parse arguments
    SKIP_ROOT_CHECK=false
    SKIP_ANSIBLE=false
    VAULT_PASSWORD_FILE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) TARGET_DIR="$2"; shift 2 ;;
            --skip-root-check) SKIP_ROOT_CHECK=true; shift ;;
            --skip-ansible) SKIP_ANSIBLE=true; shift ;;
            --vault-password-file) VAULT_PASSWORD_FILE="$2"; shift 2 ;;
            --help)
                echo "Usage: $0 [options]"
                echo "  --target <dir>         Installation target directory"
                echo "  --skip-root-check      Skip root privilege check"
                echo "  --skip-ansible         Skip Ansible installation"
                echo "  --vault-password-file   Path to vault password file"
                exit 0
                ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    check_root
    check_command python3
    check_command git
    check_command openssl

    if [[ "${SKIP_ANSIBLE}" != "true" ]]; then
        install_system_dependencies
        setup_python_environment
    fi

    setup_directories
    setup_logging
    setup_ssh
    setup_git
    setup_git_crypt
    setup_awx
    setup_systemd_service
    configure_firewall
    create_ansible_vault
    run_validation

    echo ""
    echo "============================================"
    echo -e "${GREEN} Bootstrap Complete!${NC}"
    echo "============================================"
    echo ""
    echo " Next steps:"
    echo "   1. Edit vault credentials:"
    echo "      ansible-vault edit ${ANSIBLE_DIR}/vault/vault.yml"
    echo ""
    echo "   2. Test connectivity:"
    echo "      source ${VENV_DIR}/bin/activate"
    echo "      ansible all -i ${ANSIBLE_DIR}/inventory/production/hosts.yml -m ping --limit fgt-sandbox-lab"
    echo ""
    echo "   3. Run first backup:"
    echo "      ansible-playbook ${ANSIBLE_DIR}/playbooks/backup.yml --check"
    echo "      ansible-playbook ${ANSIBLE_DIR}/playbooks/backup.yml"
    echo ""
    echo "   4. Enable backup exporter:"
    echo "      systemctl enable --now fortigate-backup-exporter.timer"
    echo ""
    echo "   5. Set up monitoring:"
    echo "      docker-compose -f ${PROJECT_ROOT}/ci_cd/docker-compose/monitoring-stack.yml up -d"
    echo ""
    echo "============================================"
}

main "$@"
