#!/usr/bin/env bash
# ============================================
# WSL2 Detection & Path Resolution
# ============================================
# Source this file from any Bash script to get
# cross-platform path resolution.
#
# Usage:
#   source "$(dirname "$0")/../wsl/detect.inc.sh"
#   echo "WSL root: $WSL_ROOT"
#   echo "Win root: $WIN_ROOT"
# ============================================

# Detect if running inside WSL2
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
    WSL_DISTRO_NAME=$(lsb_release -sd 2>/dev/null | tr -d '"' || echo "unknown")
    WSL_KERNEL=$(uname -r)
else
    IS_WSL=false
fi

# Resolve project root (works both in WSL2 and Linux)
resolve_project_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    local project_root="${script_dir}"

    # Navigate up to find project root (contains ansible/ and scripts/)
    while [[ "$project_root" != "/" ]] && \
          [[ ! -f "${project_root}/ansible/ansible.cfg" ]]; do
        project_root="$(dirname "$project_root")"
    done

    if [[ "$project_root" == "/" ]]; then
        # Fallback: assume we're in the project already
        project_root="$(pwd)"
    fi

    echo "$project_root"
}

# Resolve Windows path from WSL2 path
wsl_to_win_path() {
    local wsl_path="$1"
    if [[ "$IS_WSL" == true ]]; then
        wslpath -w "$wsl_path" 2>/dev/null || echo "$wsl_path"
    else
        echo "$wsl_path"
    fi
}

# Resolve WSL2 path from Windows path
win_to_wsl_path() {
    local win_path="$1"
    if [[ "$IS_WSL" == true ]]; then
        wslpath -u "$win_path" 2>/dev/null || echo "$win_path"
    else
        echo "$win_path"
    fi
}

# Get the best path for a file (works cross-platform)
resolve_path() {
    local path="$1"
    echo "$path"
}

# Detect Docker availability
detect_docker() {
    if command -v docker &>/dev/null; then
        DOCKER_AVAILABLE=true
        DOCKER_COMPOSE_AVAILABLE=$(docker compose version &>/dev/null && echo true || echo false)
    else
        DOCKER_AVAILABLE=false
        DOCKER_COMPOSE_AVAILABLE=false
    fi
}

# Detect backup directory
detect_backup_dir() {
    if [[ "$IS_WSL" == true ]]; then
        # In WSL2, prefer Windows filesystem for backups (persistent)
        local win_home
        win_home=$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')" 2>/dev/null || echo "$HOME")
        BACKUP_DIR="${win_home}/fortigate-backups"
    else
        BACKUP_DIR="/opt/backups/fortigates"
    fi

    # Fallback to /opt if in WSL2 but wslpath fails
    if [[ "$IS_WSL" == true ]] && [[ ! -d "$BACKUP_DIR" ]]; then
        BACKUP_DIR="/opt/backups/fortigates"
    fi

    echo "$BACKUP_DIR"
}

# Export variables
PROJECT_ROOT=$(resolve_project_root)
IS_WSL=$IS_WSL
WSL_DISTRO_NAME=${WSL_DISTRO_NAME:-linux}
BACKUP_DIR=$(detect_backup_dir)
detect_docker

# Cross-platform paths
ANSIBLE_DIR="${PROJECT_ROOT}/ansible"
SCRIPTS_DIR="${PROJECT_ROOT}/scripts"
VENV_DIR="${PROJECT_ROOT}/venv"
LOG_DIR="/var/log/fortigate-backup"

# Override LOG_DIR for WSL2
if [[ "$IS_WSL" == true ]] && [[ ! -d "$LOG_DIR" ]]; then
    LOG_DIR="${BACKUP_DIR}/logs"
    mkdir -p "$LOG_DIR" 2>/dev/null
fi

export PROJECT_ROOT IS_WSL BACKUP_DIR ANSIBLE_DIR SCRIPTS_DIR VENV_DIR LOG_DIR
