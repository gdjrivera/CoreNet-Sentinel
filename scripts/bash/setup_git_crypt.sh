#!/usr/bin/env bash
# ============================================
# git-crypt Setup for FortiGate Backup Repository
# ============================================
# Configures git-crypt to encrypt sensitive
# configuration files in the backup repository.
#
# Prerequisites:
#   - git-crypt installed (apt-get install git-crypt)
#   - GPG key pair for each team member
#
# Usage:
#   ./setup_git_crypt.sh
#   ./setup_git_crypt.sh --repo /opt/backups/fortigates
#   ./setup_git_crypt.sh --add-user admin@internal.local
#   ./setup_git_crypt.sh --unlock
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-/opt/backups/fortigates}"
GIT_CRYPT_KEY="${REPO_DIR}/.git-crypt-key"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_git_crypt() {
    if ! command -v git-crypt &>/dev/null; then
        log_error "git-crypt is not installed."
        log_info "Install it with:"
        log_info "  apt-get install git-crypt"
        log_info "  brew install git-crypt"
        log_info "  yum install git-crypt"
        exit 1
    fi
    log_ok "git-crypt found: $(git-crypt --version)"
}

check_repo() {
    if [[ ! -d "${REPO_DIR}/.git" ]]; then
        log_error "Not a git repository: ${REPO_DIR}"
        log_info "Initialize first: git init ${REPO_DIR}"
        exit 1
    fi
    log_ok "Git repository: ${REPO_DIR}"
}

init_crypt() {
    log_info "Initializing git-crypt in repository..."
    cd "${REPO_DIR}"

    if [[ -f ".git-crypt" ]]; then
        log_warn "git-crypt already initialized"
        return
    fi

    git-crypt init
    log_ok "git-crypt initialized"

    # Export key for backup
    git-crypt export-key "${GIT_CRYPT_KEY}"
    chmod 0400 "${GIT_CRYPT_KEY}"
    log_ok "Export key saved: ${GIT_CRYPT_KEY}"
    log_warn "IMPORTANT: Store ${GIT_CRYPT_KEY} in a secure location!"
    log_warn "  Recommended: scp ${GIT_CRYPT_KEY} backup@vault.internal.local:secrets/"
}

setup_gitattributes() {
    log_info "Configuring .gitattributes for encrypted files..."

    cd "${REPO_DIR}"

    cat > .gitattributes << 'GITATTRIBUTES'
# ============================================
# git-crypt encrypted file patterns
# ============================================
# Credentials and secrets
*.key filter=git-crypt diff=git-crypt
*.pem filter=git-crypt diff=git-crypt
*.cert filter=git-crypt diff=git-crypt
*.p12 filter=git-crypt diff=git-crypt
*.jks filter=git-crypt diff=git-crypt

# Configuration files containing secrets
*password* filter=git-crypt diff=git-crypt
*secret* filter=git-crypt diff=git-crypt
*credential* filter=git-crypt diff=git-crypt
*token* filter=git-crypt diff=git-crypt
*api-key* filter=git-crypt diff=git-crypt

# Vault files
*vault* filter=git-crypt diff=git-crypt
*.vault filter=git-crypt diff=git-crypt

# Environment files
.env filter=git-crypt diff=git-crypt
.env.* filter=git-crypt diff=git-crypt

# SSH keys
id_* filter=git-crypt diff=git-crypt

# Encrypt entire directories if needed
secrets/** filter=git-crypt diff=git-crypt
credentials/** filter=git-crypt diff=git-crypt
GITATTRIBUTES

    log_ok ".gitattributes configured"
    log_info "Encrypted file patterns:"
    grep -v '^#' .gitattributes | grep -v '^$' | while read -r line; do
        echo "  ${line}"
    done
}

add_gpg_user() {
    local gpg_key_id="${1:-}"

    if [[ -z "${gpg_key_id}" ]]; then
        log_error "Usage: $0 --add-user <gpg-key-id-or-email>"
        exit 1
    fi

    cd "${REPO_DIR}"

    if ! gpg --list-keys "${gpg_key_id}" &>/dev/null; then
        log_warn "GPG key not found locally: ${gpg_key_id}"
        log_info "Import the public key first:"
        log_info "  gpg --import public-key.asc"
        log_info "  gpg --recv-keys ${gpg_key_id}"
        exit 1
    fi

    git-crypt add-gpg-user "${gpg_key_id}"
    log_ok "GPG user added: ${gpg_key_id}"
}

add_symmetric_key() {
    local key_file="${1:-${GIT_CRYPT_KEY}}"

    if [[ ! -f "${key_file}" ]]; then
        log_error "Key file not found: ${key_file}"
        exit 1
    fi

    cd "${REPO_DIR}"
    git-crypt add-key "${key_file}"
    log_ok "Symmetric key added from: ${key_file}"
}

unlock_repo() {
    cd "${REPO_DIR}"

    if git-crypt unlock &>/dev/null; then
        log_ok "Repository unlocked"
    else
        log_warn "Could not unlock with default key"
        log_info "Try: git-crypt unlock /path/to/git-crypt-key"
    fi
}

lock_repo() {
    cd "${REPO_DIR}"
    git-crypt lock
    log_ok "Repository locked"
}

status_check() {
    cd "${REPO_DIR}"

    echo ""
    echo "============================================"
    echo " git-crypt Status"
    echo "============================================"

    if git-crypt status &>/dev/null; then
        log_ok "Repository is UNLOCKED"
        echo ""
        echo "Encrypted files:"
        git-crypt status | while read -r line; do
            echo "  ${line}"
        done
    else
        log_info "Repository is LOCKED"
        echo ""
        echo "To unlock: git-crypt unlock [key-file]"
    fi

    echo ""
    echo "GPG users granted access:"
    git-crypt add-gpg-user --list 2>/dev/null || echo "  (none configured yet)"
}

export_key() {
    local output="${1:-${GIT_CRYPT_KEY}}"

    cd "${REPO_DIR}"
    git-crypt export-key "${output}"
    chmod 0400 "${output}"
    log_ok "Key exported to: ${output}"
    log_warn "SECURITY: Store this key in a vault/password manager!"
}

# ============================================
# Main
# ============================================
main() {
    local action="init"
    local gpg_user=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) REPO_DIR="$2"; shift 2 ;;
            --init) action="init"; shift ;;
            --add-user) action="add_user"; gpg_user="$2"; shift 2 ;;
            --add-key) action="add_key"; GIT_CRYPT_KEY="$2"; shift 2 ;;
            --unlock) action="unlock"; shift ;;
            --lock) action="lock"; shift ;;
            --status) action="status"; shift ;;
            --export-key) action="export_key"; GIT_CRYPT_KEY="${2:-${GIT_CRYPT_KEY}}"; shift 2 ;;
            --help)
                echo "Usage: $0 [options]"
                echo "  --repo <path>          Repository path (default: /opt/backups/fortigates)"
                echo "  --init                 Initialize git-crypt"
                echo "  --add-user <gpg-id>    Add GPG user"
                echo "  --add-key <file>       Add symmetric key"
                echo "  --unlock               Unlock repository"
                echo "  --lock                 Lock repository"
                echo "  --status               Show git-crypt status"
                echo "  --export-key [file]    Export git-crypt key"
                exit 0
                ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    check_git_crypt

    case "${action}" in
        init)
            check_repo
            init_crypt
            setup_gitattributes
            log_ok "git-crypt setup complete!"
            echo ""
            echo "Next steps:"
            echo "  1. Add team members:"
            echo "     $0 --add-user admin@internal.local"
            echo ""
            echo "  2. Commit and push:"
            echo "     git -C ${REPO_DIR} add .gitattributes"
            echo "     git -C ${REPO_DIR} commit -m 'Add git-crypt configuration'"
            echo "     git -C ${REPO_DIR} push"
            echo ""
            echo "  3. Share git-crypt key securely:"
            echo "     $0 --export-key /backup/secure/git-crypt-key"
            ;;
        add_user)
            check_repo
            add_gpg_user "${gpg_user}"
            ;;
        add_key)
            check_repo
            add_symmetric_key "${GIT_CRYPT_KEY}"
            ;;
        unlock)
            check_repo
            unlock_repo
            ;;
        lock)
            check_repo
            lock_repo
            ;;
        status)
            check_repo
            status_check
            ;;
        export_key)
            check_repo
            export_key "${GIT_CRYPT_KEY}"
            ;;
    esac
}

main "$@"
