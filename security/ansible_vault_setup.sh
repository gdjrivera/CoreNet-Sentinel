#!/usr/bin/env bash
# ============================================
# Ansible Vault Setup Script
# ============================================
# Configures Ansible Vault with best practices.
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VAULT_DIR="${PROJECT_ROOT}/ansible/vault"
VAULT_FILE="${VAULT_DIR}/vault.yml"
VAULT_PASSWORD_FILE="${VAULT_DIR}/.vault_password"
VAULT_PASSWORD_LENGTH=64

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

generate_password() {
    local password_file="$1"
    local length="${2:-64}"

    # Generate using multiple sources for entropy
    {
        openssl rand -base64 "$((length * 2))"
        date +%s%N
        head -c 512 /dev/urandom 2>/dev/null || echo "${RANDOM}${RANDOM}"
    } | tr -d '\n' | tr -c 'A-Za-z0-9!@#$%^&*()-_=+' 'X' | head -c "${length}" > "${password_file}"

    chmod 0400 "${password_file}"
    log_ok "Vault password generated: ${password_file}"
}

create_vault_file() {
    local vault_file="$1"
    local template_content

    template_content=$(cat << 'VAULT'
---
# ============================================
# Ansible Vault - FortiGate Backup Credentials
# ============================================
# Edit with: ansible-vault edit ansible/vault/vault.yml
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
vault_syslog_server: "syslog.internal.local"

# Email
vault_smtp_server: "smtp.internal.local"
vault_smtp_port: 587
vault_smtp_user: "backup-notify@internal.local"
vault_smtp_password: "CHANGE_ME_SMTP_PASSWORD"
VAULT
    )

    echo "${template_content}" > "${vault_file}"
    log_ok "Vault template created: ${vault_file}"
}

encrypt_vault() {
    local vault_file="$1"
    local password_file="$2"

    if command -v ansible-vault &>/dev/null; then
        ansible-vault encrypt "${vault_file}" \
            --vault-password-file "${password_file}" 2>&1
        log_ok "Vault encrypted with Ansible Vault"
    else
        log_warn "ansible-vault not found. Install with: pip install ansible-core"
        log_warn "Manual encryption: ansible-vault encrypt ${vault_file}"
    fi
}

setup_vault_in_gitignore() {
    local gitignore="${PROJECT_ROOT}/.gitignore"
    if ! grep -q "vault_password" "${gitignore}" 2>/dev/null; then
        echo -e "\n# Ansible Vault\n.vault_password\n.vault_password_*" >> "${gitignore}"
        log_ok "Updated .gitignore for vault password"
    fi
}

setup_pre_commit() {
    local pre_commit="${PROJECT_ROOT}/.pre-commit-config.yaml"
    if [[ -f "${pre_commit}" ]]; then
        if ! grep -q "detect-secrets\|detect-private-key" "${pre_commit}" 2>/dev/null; then
            log_info "Consider adding detect-secrets to pre-commit hooks"
        fi
    fi
}

show_instructions() {
    log_info ""
    log_info "============================================"
    log_info "VAULT SETUP COMPLETE"
    log_info "============================================"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Edit vault credentials:"
    log_info "     ansible-vault edit ${VAULT_FILE}"
    log_info ""
    log_info "  2. Store vault password securely:"
    log_info "     - Password: $(cat ${VAULT_PASSWORD_FILE})"
    log_info "     - Store in: HashiCorp Vault / password manager / offline safe"
    log_info ""
    log_info "  3. For CI/CD, set environment variable:"
    log_info "     ANSIBLE_VAULT_PASSWORD_FILE=.vault_password"
    log_info ""
    log_info "  4. Backup vault password file to secure location:"
    log_info "     cp ${VAULT_PASSWORD_FILE} /backup/secure/vault-password-backup"
    log_info "============================================"
}

main() {
    mkdir -p "${VAULT_DIR}"

    if [[ -f "${VAULT_PASSWORD_FILE}" ]]; then
        log_warn "Vault password already exists: ${VAULT_PASSWORD_FILE}"
    else
        generate_password "${VAULT_PASSWORD_FILE}" "${VAULT_PASSWORD_LENGTH}"
    fi

    if [[ -f "${VAULT_FILE}" ]]; then
        log_warn "Vault file already exists: ${VAULT_FILE}"
    else
        create_vault_file "${VAULT_FILE}"
        encrypt_vault "${VAULT_FILE}" "${VAULT_PASSWORD_FILE}"
    fi

    setup_vault_in_gitignore
    setup_pre_commit
    show_instructions
}

main "$@"
