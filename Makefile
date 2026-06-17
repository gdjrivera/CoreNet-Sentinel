# ============================================
# FortiGate Backup System - Makefile
# ============================================
# Cross-platform: Linux native + WSL2
#
# Usage:
#   make help        - Show this help
#   make setup       - Full system setup
#   make backup      - Run backup playbook
#   make validate    - Validate configuration
#   make security    - Security scan
#   make report      - Generate report
#   make monitor     - Start monitoring stack
#   make wsl-setup   - Setup WSL2 from Windows (via PowerShell)
#   make win-cmd     - Run Ansible from Windows PowerShell
#   make test        - Run tests
#   make clean       - Clean up
# ============================================

SHELL := /bin/bash
.PHONY: help setup backup validate security report monitor test clean lint

PROJECT_DIR := $(shell pwd)
ANSIBLE_DIR := $(PROJECT_DIR)/ansible
SCRIPTS_DIR := $(PROJECT_DIR)/scripts
VENV_DIR := $(PROJECT_DIR)/venv

# WSL2-aware backup directory
IS_WSL := $(shell grep -qi microsoft /proc/version 2>/dev/null && echo true || echo false)
ifeq ($(IS_WSL),true)
BACKUP_DIR := $(shell wslpath -u "$$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')" 2>/dev/null)/fortigate-backups/data
else
BACKUP_DIR := /opt/backups/fortigates
endif

INVENTORY := $(ANSIBLE_DIR)/inventory/production/hosts.yml
VAULT_PASS := $(ANSIBLE_DIR)/vault/.vault_password
WSL_DISTRO := Ubuntu-24.04

# Colors
GREEN := \033[0;32m
BLUE := \033[0;34m
YELLOW := \033[1;33m
NC := \033[0m

help:
	@echo ""
	@echo "$(BLUE)FortiGate Backup System - Makefile$(NC)"
	@echo "============================================"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "$(GREEN)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""

# ============================================
# Setup
# ============================================

setup: ## Full system setup (bootstrap)
	@echo "$(BLUE)Running full system setup...$(NC)"
	@sudo $(SCRIPTS_DIR)/bash/bootstrap.sh
	@echo "$(GREEN)Setup complete!$(NC)"

setup-dev: ## Development setup (without sudo)
	@echo "$(BLUE)Setting up development environment...$(NC)"
	@python3 -m venv $(VENV_DIR)
	@source $(VENV_DIR)/bin/activate && pip install -r requirements.txt
	@source $(VENV_DIR)/bin/activate && ansible-galaxy collection install fortinet.fortios community.network
	@echo "$(GREEN)Development environment ready!$(NC)"

setup-precommit: ## Install pre-commit hooks
	@pre-commit install
	@echo "$(GREEN)Pre-commit hooks installed$(NC)"

# ============================================
# Backups
# ============================================

backup: ## Run full backup
	@echo "$(BLUE)Running FortiGate backup...$(NC)"
	@source $(VENV_DIR)/bin/activate && \
		ansible-playbook $(ANSIBLE_DIR)/playbooks/backup.yml \
			-i $(INVENTORY) \
			--vault-password-file $(VAULT_PASS)
	@echo "$(GREEN)Backup complete!$(NC)"

backup-check: ## Run backup in check (dry-run) mode
	@echo "$(BLUE)Running backup check (dry-run)...$(NC)"
	@source $(VENV_DIR)/bin/activate && \
		ansible-playbook $(ANSIBLE_DIR)/playbooks/backup.yml \
			-i $(INVENTORY) \
			--vault-password-file $(VAULT_PASS) \
			--check
	@echo "$(GREEN)Check complete!$(NC)"

backup-region: ## Run backup for specific region: make backup-region R=centro
	@echo "$(BLUE)Running backup for region $(R)...$(NC)"
	@source $(VENV_DIR)/bin/activate && \
		ansible-playbook $(ANSIBLE_DIR)/playbooks/backup.yml \
			-i $(INVENTORY) \
			--vault-password-file $(VAULT_PASS) \
			--limit region_$(R)
	@echo "$(GREEN)Backup for region $(R) complete!$(NC)"

# ============================================
# Validation
# ============================================

validate: ## Validate all configurations
	@echo "$(BLUE)Validating configurations...$(NC)"
	@source $(VENV_DIR)/bin/activate && \
		ansible-playbook $(ANSIBLE_DIR)/playbooks/validate_all.yml \
			-i $(INVENTORY) \
			--vault-password-file $(VAULT_PASS)
	@echo "$(GREEN)Validation complete!$(NC)"

validate-inventory: ## Validate Ansible inventory
	@echo "$(BLUE)Validating inventory...$(NC)"
	@ansible-inventory -i $(INVENTORY) --list > /dev/null
	@python3 $(SCRIPTS_DIR)/python/inventory_generator.py --validate --inventory $(INVENTORY)
	@echo "$(GREEN)Inventory valid!$(NC)"

# ============================================
# Security
# ============================================

security: ## Run all security checks
	@echo "$(BLUE)Running security checks...$(NC)"
	@python3 $(SCRIPTS_DIR)/python/secrets_scanner.py --dir $(ANSIBLE_DIR) --ci-mode || true
	@python3 $(SCRIPTS_DIR)/python/secrets_scanner.py --dir $(SCRIPTS_DIR) --ci-mode || true
	@echo "$(GREEN)Security scan complete!$(NC)"

security-rotate: ## Rotate SSH keys and API tokens
	@echo "$(BLUE)Rotating credentials...$(NC)"
	@sudo $(SCRIPTS_DIR)/bash/rotate_credentials.sh --all
	@echo "$(GREEN)Credential rotation complete!$(NC)"

# ============================================
# Reporting
# ============================================

report: ## Generate daily backup report
	@echo "$(BLUE)Generating backup report...$(NC)"
	@python3 $(SCRIPTS_DIR)/python/report_generator.py \
		--backup-dir $(BACKUP_DIR) \
		--date $(shell date +%Y-%m-%d) \
		--format html \
		--output reports/backup-report-$(shell date +%Y-%m-%d).html
	@echo "$(GREEN)Report generated: reports/backup-report-$(shell date +%Y-%m-%d).html$(NC)"

# ============================================
# Monitoring
# ============================================

monitor: ## Start monitoring stack (Docker)
	@echo "$(BLUE)Starting monitoring stack...$(NC)"
ifeq ($(IS_WSL),true)
	@echo "$(YELLOW)Note: Docker Desktop for Windows must be running$(NC)"
	@docker compose -f $(PROJECT_DIR)/ci_cd/docker-compose/monitoring-stack.yml up -d
else
	@docker compose -f $(PROJECT_DIR)/ci_cd/docker-compose/monitoring-stack.yml up -d
endif
	@echo "$(GREEN)Monitoring stack started!$(NC)"
	@echo "  Grafana: http://localhost:3000 (admin/admin123)"
	@echo "  Prometheus: http://localhost:9090"
	@echo "  Alertmanager: http://localhost:9093"

monitor-stop: ## Stop monitoring stack
	@docker-compose -f $(PROJECT_DIR)/ci_cd/docker-compose/monitoring-stack.yml down

monitor-logs: ## View monitoring logs
	@docker-compose -f $(PROJECT_DIR)/ci_cd/docker-compose/monitoring-stack.yml logs -f

# ============================================
# Testing
# ============================================

test: ## Run all tests
	@echo "$(BLUE)Running tests...$(NC)"
	@source $(VENV_DIR)/bin/activate && \
		python3 -m pytest tests/ -v --cov=scripts/python --cov-report=term-missing
	@echo "$(GREEN)Tests complete!$(NC)"

test-scripts: ## Test Python scripts import
	@echo "$(BLUE)Testing Python scripts...$(NC)"
	@python3 -c "from scripts.python.config_validator import main; print('config_validator: OK')"
	@python3 -c "from scripts.python.secrets_scanner import main; print('secrets_scanner: OK')"
	@python3 -c "from scripts.python.hash_verifier import main; print('hash_verifier: OK')"
	@python3 -c "from scripts.python.metadata_logger import main; print('metadata_logger: OK')"
	@python3 -c "from scripts.python.report_generator import main; print('report_generator: OK')"
	@python3 -c "from scripts.python.health_check import main; print('health_check: OK')"
	@echo "$(GREEN)All Python scripts import successfully!$(NC)"

# ============================================
# Code Quality
# ============================================

lint: ## Run all linters
	@echo "$(BLUE)Linting Python code...$(NC)"
	@flake8 scripts/ --max-line-length=120 --extend-ignore=E203,W503
	@echo "$(BLUE)Linting YAML files...$(NC)"
	@yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' ansible/
	@echo "$(BLUE)Linting shell scripts...$(NC)"
	@shellcheck scripts/bash/*.sh -S warning || true
	@echo "$(BLUE)Running Ansible lint...$(NC)"
	@ansible-lint ansible/playbooks/*.yml -x '106|204|208|305|306|403|502' || true
	@echo "$(GREEN)Lint complete!$(NC)"

# ============================================
# Infrastructure Management
# ============================================

health: ## Run health checks
	@echo "$(BLUE)Running infrastructure health check...$(NC)"
	@python3 $(SCRIPTS_DIR)/python/health_check.py --backup-dir $(BACKUP_DIR)
	@echo "$(GREEN)Health check complete!$(NC)"

verify: ## Verify backup integrity
	@echo "$(BLUE)Verifying backup integrity...$(NC)"
	@python3 $(SCRIPTS_DIR)/python/hash_verifier.py \
		--backup-dir $(BACKUP_DIR) \
		--verify-chain
	@echo "$(GREEN)Integrity verification complete!$(NC)"

compliance: ## Run compliance checks
	@echo "$(BLUE)Running compliance checks...$(NC)"
	@python3 $(PROJECT_DIR)/security/audit/compliance_check.py \
		--rules $(PROJECT_DIR)/security/audit/audit_rules.yml \
		--backup-dir $(BACKUP_DIR) \
		--profile enhanced
	@echo "$(GREEN)Compliance check complete!$(NC)"

# ============================================
# Cleanup
# ============================================

clean: ## Clean up temporary files
	@echo "$(BLUE)Cleaning up...$(NC)"
	@find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@find . -type f -name "*.pyc" -delete 2>/dev/null || true
	@find . -type f -name "*.retry" -delete 2>/dev/null || true
	@rm -rf $(VENV_DIR)
	@rm -rf reports/
	@rm -rf .pytest_cache/
	@echo "$(GREEN)Clean complete!$(NC)"

clean-backups: ## Clean old backups (older than 90 days)
	@echo "$(BLUE)Cleaning backups older than 90 days...$(NC)"
	@find $(BACKUP_DIR) -mindepth 1 -maxdepth 1 -type d -mtime +90 -exec rm -rf {} + 2>/dev/null || true
	@echo "$(GREEN)Old backups cleaned!$(NC)"

# ============================================
# DR (Disaster Recovery)
# ============================================

dr-status: ## Show DR status
	@$(SCRIPTS_DIR)/bash/dr_failover.sh --status

dr-replicate: ## Replicate to DR site: make dr-replicate TARGET=user@dr-site:/path
	@echo "$(BLUE)Replicating to DR site...$(NC)"
	@$(SCRIPTS_DIR)/bash/dr_failover.sh --replicate-to $(TARGET)
	@echo "$(GREEN)Replication complete!$(NC)"

# ============================================
# Git Management
# ============================================

git-crypt-init: ## Initialize git-crypt for repository
	@$(SCRIPTS_DIR)/bash/setup_git_crypt.sh --init

git-crypt-unlock: ## Unlock git-crypt encrypted repo
	@$(SCRIPTS_DIR)/bash/setup_git_crypt.sh --unlock

git-crypt-lock: ## Lock git-crypt encrypted repo
	@$(SCRIPTS_DIR)/bash/setup_git_crypt.sh --lock

git-crypt-status: ## Show git-crypt status
	@$(SCRIPTS_DIR)/bash/setup_git_crypt.sh --status

# ============================================
# WSL2 (Windows) Integration
# ============================================

WSL2_POWERSHELL := powershell.exe -ExecutionPolicy Bypass -File

wsl-setup: ## [Windows] Bootstrap WSL2 from PowerShell (run on Windows)
	@echo "$(YELLOW)This target must be run from Windows PowerShell$(NC)"
	@echo "Run:  $(BLUE).\scripts\powershell\bootstrap-wsl.ps1$(NC)"
	@$(WSL2_POWERSHELL) "$(PROJECT_DIR)\scripts\powershell\bootstrap-wsl.ps1" 2>/dev/null || \
		echo "Run directly: powershell -File scripts/powershell/bootstrap-wsl.ps1"

wsl-backup: ## [Windows] Run backup via WSL2
	@$(WSL2_POWERSHELL) "$(PROJECT_DIR)\scripts\powershell\run-ansible.ps1" -Playbook backup.yml

wsl-validate: ## [Windows] Validate via WSL2
	@$(WSL2_POWERSHELL) "$(PROJECT_DIR)\scripts\powershell\run-ansible.ps1" -Playbook validate_all.yml

wsl-shell: ## [Windows] Open WSL2 shell in project directory
	@start wsl -d $(WSL_DISTRO) --cd /opt/fortigate-backup 2>/dev/null || \
	 start wsl --cd $(PROJECT_DIR)

win-manage: ## [Windows] Open management CLI
	@$(WSL2_POWERSHELL) "$(PROJECT_DIR)\scripts\powershell\manage.ps1" status

win-cmd: ## [Windows] Run ad-hoc Ansible command in WSL2
	@echo "Usage:  make win-cmd CMD='ansible all -m ping --limit fgt-centro-dc01'"
	@$(WSL2_POWERSHELL) "$(PROJECT_DIR)\scripts\powershell\run-ansible.ps1" -Playbook backup.yml -Check -Limit $(LIMIT)

# ============================================
# System
# ============================================

logs: ## View backup logs
ifeq ($(IS_WSL),true)
	@tail -f $(BACKUP_DIR)/../logs/*.log 2>/dev/null || echo "No logs found"
else
	@tail -f /var/log/fortigate-backup/*.log
endif

status: ## Show overall system status
	@echo ""
	@echo "$(BLUE)FortiGate Backup System Status$(NC)"
	@echo "============================================"
	@echo "Platform: $(shell uname -a | cut -d' ' -f1-3)"
ifeq ($(IS_WSL),true)
	@echo "WSL2: true"
endif
	@echo "Project: $(PROJECT_DIR)"
	@echo "Backup Directory: $(BACKUP_DIR)"
	@echo "Backup Size: $(shell du -sh $(BACKUP_DIR) 2>/dev/null | cut -f1 || echo 'N/A')"
	@echo "Backup Count: $(shell find $(BACKUP_DIR) -name '*full_config*' 2>/dev/null | wc -l || echo 'N/A')"
	@echo "Git Commits: $(shell git -C $(PROJECT_DIR) rev-list --count HEAD 2>/dev/null || echo 'N/A')"
	@echo "Disk Usage: $(shell df -h $(BACKUP_DIR) 2>/dev/null | awk 'NR==2 {print $$5}' || echo 'N/A')"
	@echo ""

.DEFAULT_GOAL := help
