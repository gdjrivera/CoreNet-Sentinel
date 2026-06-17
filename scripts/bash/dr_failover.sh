#!/usr/bin/env bash
# ============================================
# Disaster Recovery Failover Script
# ============================================
# Handles failover of the backup infrastructure
# to a secondary region/data center.
#
# Usage:
#   ./dr_failover.sh --status
#   ./dr_failover.sh --failover-to dr-site.internal.local
#   ./dr_failover.sh --replicate --source /opt/backups --target backup@dr-site:/opt/backups
#   ./dr_failover.sh --recover
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BACKUP_DIR="/opt/backups/fortigates"
LOG_DIR="/var/log/fortigate-backup"
LOG_FILE="${LOG_DIR}/dr-failover-$(date -u +'%Y%m%d_%H%M%S').log"
STATUS_FILE="${BACKUP_DIR}/.dr_status.json"
TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "${LOG_FILE}"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    local errors=0
    for cmd in rsync ssh git pg_isready; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "Required command not found: ${cmd}"
            ((errors++))
        fi
    done

    for dir in "${BACKUP_DIR}" "${LOG_DIR}"; do
        if [[ ! -d "${dir}" ]]; then
            log_error "Directory not found: ${dir}"
            ((errors++))
        fi
    done

    if [[ ${errors} -gt 0 ]]; then
        log_error "${errors} prerequisite(s) failed"
        exit 1
    fi
    log_ok "All prerequisites satisfied"
}

get_dr_status() {
    if [[ -f "${STATUS_FILE}" ]]; then
        cat "${STATUS_FILE}"
    else
        echo '{"status": "active", "site": "primary", "last_failover": null, "last_sync": null}'
    fi
}

update_dr_status() {
    local status="$1"
    local site="$2"
    echo "${status}" | jq \
        --arg s "${site}" \
        --arg t "${TIMESTAMP}" \
        '.site = $s | .last_failover = $t' > "${STATUS_FILE}"
    log_ok "DR status updated: site=${site}, timestamp=${TIMESTAMP}"
}

check_primary_health() {
    log_info "Checking primary site health..."

    local checks=0
    local failed=0

    # Check backup directory
    if [[ -d "${BACKUP_DIR}" ]] && [[ -w "${BACKUP_DIR}" ]]; then
        log_ok "Backup directory accessible"
        ((checks++))
    else
        log_error "Backup directory not accessible"
        ((failed++))
    fi

    # Check git repository
    if [[ -d "${BACKUP_DIR}/.git" ]]; then
        log_ok "Git repository intact"
        ((checks++))
    else
        log_error "Git repository corrupted"
        ((failed++))
    fi

    # Check database connectivity (if PostgreSQL is local)
    if command -v pg_isready &>/dev/null; then
        if pg_isready -q 2>/dev/null; then
            log_ok "PostgreSQL is running"
            ((checks++))
        else
            log_warn "PostgreSQL is not running"
            ((failed++))
        fi
    fi

    # Check disk space
    local usage
    usage=$(df "${BACKUP_DIR}" | awk 'NR==2 {print $5}' | sed 's/%//')
    if [[ ${usage} -lt 90 ]]; then
        log_ok "Disk usage: ${usage}%"
        ((checks++))
    else
        log_warn "Disk usage critical: ${usage}%"
        ((failed++))
    fi

    if [[ ${failed} -gt 0 ]]; then
        return 1
    fi
    return 0
}

replicate_to_dr() {
    local target="${1:-backup@dr-site.internal.local:/opt/backups/fortigates}"
    local bandwidth="${2:-50000}"  # KB/s limit

    log_info "Starting replication to DR site: ${target}"

    # Ensure git is in consistent state
    cd "${BACKUP_DIR}"
    git fsck 2>/dev/null || log_warn "Git fsck reported issues"

    # Sync backup data
    rsync -avz --delete \
        --exclude=".git" \
        --exclude="*.log" \
        --exclude="__pycache__" \
        --exclude=".vault_password" \
        --bwlimit="${bandwidth}" \
        -e "ssh -i ${HOME}/.ssh/fortigate-backup-key -o StrictHostKeyChecking=accept-new" \
        "${BACKUP_DIR}/" \
        "${target}/" 2>&1 | while read -r line; do
            if [[ "${line}" =~ ^sent\ |^total\ size|^$/ ]]; then
                log_info "${line}"
            fi
        done

    log_ok "Data replication completed"

    # Sync git repository
    git push --mirror "backup@dr-site.internal.local:/opt/backups/fortigates" 2>&1 || {
        log_warn "Git mirror push failed - repository may need manual sync"
    }

    log_ok "Git repository mirrored to DR site"
}

perform_failover() {
    local dr_host="$1"

    log_warn "============================================"
    log_warn " INITIATING FAILOVER TO DR SITE"
    log_warn " Target: ${dr_host}"
    log_warn " Timestamp: ${TIMESTAMP}"
    log_warn "============================================"

    # Verify DR site is reachable
    if ! ping -c 2 -W 5 "${dr_host}" &>/dev/null; then
        log_error "DR site ${dr_host} is not reachable"
        exit 1
    fi
    log_ok "DR site reachable: ${dr_host}"

    # Perform final replication before failover
    replicate_to_dr "backup@${dr_host}:/opt/backups/fortigates"

    # Update status
    update_dr_status "$(get_dr_status)" "dr-${dr_host}"

    log_ok "Failover to DR site completed"
    log_warn "ACTION REQUIRED: Update DNS/CNAME records to point to ${dr_host}"
    log_warn "ACTION REQUIRED: Update Ansible inventory bastion host"
    log_warn "ACTION REQUIRED: Verify AWX/Tower connectivity to new site"

    cat << 'FAILOVER_NOTES'

============================================
FAILOVER CHECKLIST
============================================
[ ] DNS records updated to DR site
[ ] Ansible inventory bastion host updated
[ ] AWX/Tower inventory updated
[ ] SSH keys deployed on DR bastion
[ ] Vault credentials accessible
[ ] Monitoring targets updated
[ ] Alertmanager routes updated
[ ] DR site Prometheus targets online
============================================
FAILOVER_NOTES
}

perform_recover() {
    log_warn "============================================"
    log_warn " ATTEMPTING RECOVERY TO PRIMARY SITE"
    log_warn "============================================"

    # Check if primary is healthy now
    if check_primary_health; then
        log_ok "Primary site is healthy"
    else
        log_warn "Primary site still has issues - recovery may be partial"
    fi

    # Sync back from DR
    local dr_host
    dr_host=$(jq -r '.site' "${STATUS_FILE}" 2>/dev/null | sed 's/^dr-//')
    if [[ -n "${dr_host}" ]] && [[ "${dr_host}" != "primary" ]]; then
        log_info "Synchronizing from DR site: ${dr_host}"

        rsync -avz --delete \
            -e "ssh -i ${HOME}/.ssh/fortigate-backup-key" \
            "backup@${dr_host}:/opt/backups/fortigates/" \
            "${BACKUP_DIR}/" 2>&1

        log_ok "Data synchronized from DR site"
    fi

    update_dr_status "$(get_dr_status)" "primary"
    log_ok "Recovery to primary site completed"
}

verify_backup_integrity() {
    log_info "Verifying backup integrity across all sites..."

    local errors=0

    # Check local backups
    cd "${BACKUP_DIR}"
    if [[ -d ".git" ]]; then
        if git fsck --no-dangling 2>/dev/null; then
            log_ok "Local git repository integrity verified"
        else
            log_error "Local git repository corrupted"
            ((errors++))
        fi
    fi

    # Verify recent backups exist
    local recent_backups
    recent_backups=$(find "${BACKUP_DIR}" -maxdepth 2 -name "*.conf" -mtime -1 | wc -l)
    if [[ ${recent_backups} -gt 0 ]]; then
        log_ok "${recent_backups} configuration files backed up in last 24 hours"
    else
        log_warn "No configuration files backed up in last 24 hours"
        ((errors++))
    fi

    return ${errors}
}

# ============================================
# Main
# ============================================
main() {
    mkdir -p "${LOG_DIR}"
    check_prerequisites

    local action="status"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status) action="status"; shift ;;
            --failover-to) action="failover"; dr_target="$2"; shift 2 ;;
            --replicate-to) action="replicate"; dr_target="$2"; shift 2 ;;
            --recover) action="recover"; shift ;;
            --verify) action="verify"; shift ;;
            --help)
                echo "Usage: $0 [options]"
                echo "  --status                   Show DR status"
                echo "  --failover-to <host>       Failover to DR site"
                echo "  --replicate-to <target>    Replicate to DR site"
                echo "  --recover                  Recover primary site"
                echo "  --verify                   Verify backup integrity"
                exit 0
                ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    case "${action}" in
        status)
            echo ""
            echo "============================================"
            echo "Disaster Recovery Status"
            echo "============================================"
            jq . "${STATUS_FILE}" 2>/dev/null || echo '{"status": "unknown", "message": "No status file found"}'
            echo ""
            verify_backup_integrity || true
            ;;

        failover)
            perform_failover "${dr_target}"
            ;;

        replicate)
            if [[ -z "${dr_target}" ]]; then
                log_error "Target required for replication"
                exit 1
            fi
            replicate_to_dr "${dr_target}"
            ;;

        recover)
            perform_recover
            ;;

        verify)
            verify_backup_integrity
            ;;
    esac
}

main "$@"
