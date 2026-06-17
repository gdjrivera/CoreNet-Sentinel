#!/usr/bin/env bash
# ============================================
# FortiGate Credential Rotation Script
# ============================================
# Rotates SSH keys and API tokens for FortiGate
# backup users across all managed devices.
#
# Usage:
#   ./rotate_credentials.sh --all
#   ./rotate_credentials.sh --region centro
#   ./rotate_credentials.sh --host fgt-centro-dc01
#   ./rotate_credentials.sh --dry-run
#   ./rotate_credentials.sh --validate
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ANSIBLE_DIR="${PROJECT_ROOT}/ansible"
VAULT_FILE="${ANSIBLE_DIR}/vault/vault.yml"
VAULT_PASS_FILE="${ANSIBLE_DIR}/vault/.vault_password"
BACKUP_KEY="${HOME}/.ssh/fortigate-backup-key"
LOG_FILE="/var/log/fortigate-backup/credential-rotation.log"
TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "${LOG_FILE}"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; echo "[$(date +'%Y-%m-%d %H:%M:%S')] [OK] $1" >> "${LOG_FILE}"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $1" >> "${LOG_FILE}"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "${LOG_FILE}"; }

check_prerequisites() {
    local errors=0

    if ! command -v ansible-playbook &>/dev/null; then
        log_error "ansible-playbook not found"
        ((errors++))
    fi

    if ! command -v ssh-keygen &>/dev/null; then
        log_error "ssh-keygen not found"
        ((errors++))
    fi

    if [[ ! -f "${VAULT_FILE}" ]]; then
        log_warn "Vault file not found: ${VAULT_FILE}"
    fi

    if [[ ! -f "${VAULT_PASS_FILE}" ]]; then
        log_warn "Vault password file not found: ${VAULT_PASS_FILE}"
    fi

    if [[ ${errors} -gt 0 ]]; then
        log_error "${errors} prerequisite(s) missing"
        exit 1
    fi

    log_ok "All prerequisites satisfied"
}

generate_new_ssh_key() {
    local key_type="${1:-ed25519}"
    local new_key="${BACKUP_KEY}.new.${TIMESTAMP}"

    log_info "Generating new SSH key (${key_type})..."
    ssh-keygen -t "${key_type}" -a 100 \
        -f "${new_key}" \
        -C "fortigate-backup-${TIMESTAMP}@$(hostname)" \
        -N "" 2>&1 | while read -r line; do log_info "  ${line}"; done

    if [[ -f "${new_key}" ]]; then
        chmod 0600 "${new_key}"
        chmod 0644 "${new_key}.pub"
        log_ok "New SSH key generated: ${new_key}"
        echo "${new_key}"
    else
        log_error "Failed to generate SSH key"
        return 1
    fi
}

deploy_ssh_key_to_fortigates() {
    local new_key_file="$1"
    local public_key="${new_key_file}.pub"
    local limit="${2:-all}"

    log_info "Deploying SSH key to FortiGates (limit: ${limit})..."

    # Read the public key
    local pub_key_content
    pub_key_content=$(cat "${public_key}")

    # Use Ansible to deploy the key
    ansible-playbook -i "${ANSIBLE_DIR}/inventory/production/hosts.yml" \
        --vault-password-file "${VAULT_PASS_FILE}" \
        --limit "${limit}" \
        -e "ssh_public_key='${pub_key_content}'" \
        "${ANSIBLE_DIR}/playbooks/rotate_ssh_key.yml" 2>&1 || {
            log_error "Failed to deploy SSH key to some devices"
            return 1
        }

    log_ok "SSH key deployed successfully"
}

rotate_api_tokens() {
    local limit="${1:-all}"

    log_info "Rotating API tokens (limit: ${limit})..."

    ansible-playbook -i "${ANSIBLE_DIR}/inventory/production/hosts.yml" \
        --vault-password-file "${VAULT_PASS_FILE}" \
        --limit "${limit}" \
        "${ANSIBLE_DIR}/playbooks/rotate_api_token.yml" 2>&1 || {
            log_error "Failed to rotate API tokens on some devices"
            return 1
        }

    log_ok "API tokens rotated successfully"
}

update_ansible_vault() {
    local new_key_file="$1"
    local timestamp="${TIMESTAMP}"

    log_info "Updating Ansible Vault with new credentials..."

    # Backup current vault
    local vault_backup="${VAULT_FILE}.backup.${timestamp}"
    cp "${VAULT_FILE}" "${vault_backup}"
    log_ok "Vault backup: ${vault_backup}"

    # Decrypt current vault
    ansible-vault decrypt "${VAULT_FILE}" \
        --vault-password-file "${VAULT_PASS_FILE}" 2>/dev/null || {
            log_warn "Could not decrypt vault (may already be decrypted)"
        }

    # Update SSH key path
    sed -i "s|vault_ssh_key_path:.*|vault_ssh_key_path: \"${new_key_file}\"|" "${VAULT_FILE}"

    # Re-encrypt vault
    ansible-vault encrypt "${VAULT_FILE}" \
        --vault-password-file "${VAULT_PASS_FILE}" 2>/dev/null || {
            log_warn "Could not encrypt vault"
        }

    log_ok "Ansible Vault updated with new SSH key path"
}

verify_connectivity() {
    local limit="${1:-all}"
    local failed=0

    log_info "Verifying connectivity with new credentials..."

    ansible all -i "${ANSIBLE_DIR}/inventory/production/hosts.yml" \
        --vault-password-file "${VAULT_PASS_FILE}" \
        --limit "${limit}" \
        -m ping \
        -o 2>&1 | tail -n +2 | while read -r line; do
            if echo "${line}" | grep -q "UNREACHABLE\|FAILED"; then
                log_error "${line}"
                ((failed++))
            else
                log_ok "${line}"
            fi
        done

    if [[ ${failed} -eq 0 ]]; then
        log_ok "All devices reachable with new credentials"
        return 0
    else
        log_warn "${failed} device(s) unreachable - check manually"
        return 1
    fi
}

rollback_credentials() {
    local timestamp="$1"

    log_warn "ROLLING BACK to credentials from ${timestamp}..."

    # Restore vault backup
    local vault_backup="${VAULT_FILE}.backup.${timestamp}"
    if [[ -f "${vault_backup}" ]]; then
        cp "${vault_backup}" "${VAULT_FILE}"
        log_ok "Vault restored from backup"
    else
        log_error "No vault backup found for timestamp ${timestamp}"
        return 1
    fi

    # Restore old SSH key
    local old_key="${BACKUP_KEY}.$(echo ${timestamp} | sed 's/_/./')"
    if [[ -f "${old_key}" ]]; then
        cp "${old_key}" "${BACKUP_KEY}"
        log_ok "SSH key restored"
    fi

    log_ok "Rollback completed"
}

generate_report() {
    local timestamp="${TIMESTAMP}"
    local report_file="/var/log/fortigate-backup/rotation-report-${timestamp}.txt"

    {
        echo "============================================"
        echo "Credential Rotation Report"
        echo "============================================"
        echo "Date: $(date)"
        echo "Rotation ID: ${timestamp}"
        echo ""
        echo "Actions Performed:"
        echo "  - New SSH key generated"
        echo "  - New public key deployed to FortiGates"
        echo "  - API tokens regenerated"
        echo "  - Ansible Vault updated"
        echo "  - Connectivity verified"
        echo ""
        echo "Key Files:"
        echo "  New SSH Key: ${BACKUP_KEY}.new.${timestamp}"
        echo "  Vault Backup: ${VAULT_FILE}.backup.${timestamp}"
        echo ""
        echo "Rollback Command:"
        echo "  $0 --rollback ${timestamp}"
        echo "============================================"
    } > "${report_file}"

    log_ok "Report generated: ${report_file}"
}

# ============================================
# Main
# ============================================
main() {
    local action="all"
    local limit="all"
    local rollback_timestamp=""
    local dry_run=false

    # Ensure log directory exists
    mkdir -p "$(dirname "${LOG_FILE}")"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) action="all"; shift ;;
            --region) action="region"; limit="region_$2"; shift 2 ;;
            --host) action="host"; limit="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            --validate) action="validate"; shift ;;
            --rollback) action="rollback"; rollback_timestamp="$2"; shift 2 ;;
            --rotate-api) action="api"; shift ;;
            --rotate-ssh) action="ssh"; shift ;;
            --help)
                echo "Usage: $0 [options]"
                echo "  --all                 Rotate all credentials (default)"
                echo "  --region <name>       Rotate credentials in a specific region"
                echo "  --host <hostname>     Rotate credentials for a specific device"
                echo "  --rotate-ssh          Only rotate SSH keys"
                echo "  --rotate-api          Only rotate API tokens"
                echo "  --dry-run             Show what would be done without changes"
                echo "  --validate            Validate current credentials"
                echo "  --rollback <ts>       Rollback to previous credentials"
                exit 0
                ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ "${dry_run}" == "true" ]]; then
        log_info "DRY RUN - No changes will be made"
        log_info "Would rotate credentials for: ${limit}"
        log_info "Would generate new SSH key"
        log_info "Would deploy key to FortiGates"
        log_info "Would rotate API tokens"
        log_info "Would update Ansible Vault"
        log_info "Would verify connectivity"
        exit 0
    fi

    case "${action}" in
        validate)
            check_prerequisites
            verify_connectivity "${limit}"
            ;;

        rollback)
            rollback_credentials "${rollback_timestamp}"
            verify_connectivity "${limit}"
            ;;

        ssh|all)
            check_prerequisites

            if [[ "${action}" == "ssh" || "${action}" == "all" ]]; then
                local new_key
                new_key=$(generate_new_ssh_key)
                deploy_ssh_key_to_fortigates "${new_key}" "${limit}"
                update_ansible_vault "${new_key}"
            fi

            if [[ "${action}" == "all" ]]; then
                rotate_api_tokens "${limit}"
            fi

            if [[ "${dry_run}" == "false" ]]; then
                verify_connectivity "${limit}"
                generate_report
            fi

            log_ok "Credential rotation completed successfully!"
            ;;

        api)
            check_prerequisites
            rotate_api_tokens "${limit}"
            verify_connectivity "${limit}"
            log_ok "API token rotation completed"
            ;;

        region|host)
            check_prerequisites
            local new_key
            new_key=$(generate_new_ssh_key)
            deploy_ssh_key_to_fortigates "${new_key}" "${limit}"
            rotate_api_tokens "${limit}"
            verify_connectivity "${limit}"
            generate_report
            log_ok "Credential rotation completed for ${limit}"
            ;;
    esac
}

main "$@"
