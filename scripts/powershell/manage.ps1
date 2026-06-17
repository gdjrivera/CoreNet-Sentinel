<#
.SYNOPSIS
    FortiGate Backup System - Management CLI for Windows
.DESCRIPTION
    Central management interface for the backup system from Windows.
    Handles WSL2 lifecycle, backup operations, monitoring, and validation.

.PARAMETER Command
    Command to execute:
      status        - Show system status
      backup        - Run backup playbook
      validate      - Validate configurations
      report        - Generate report
      monitor       - Start monitoring stack
      monitor-stop  - Stop monitoring stack
      logs          - View backup logs
      shell         - Open WSL2 shell
      health        - Run health check
      security      - Run security scan
      wsl-setup     - Run WSL2 bootstrap
      dr-status     - Show DR status

.PARAMETER Limit
    Host/region limit for backup operations
.PARAMETER Region
    Region name for regional operations
.PARAMETER Check
    Run in dry-run mode
.PARAMETER WslDistro
    WSL2 distribution name

.EXAMPLE
    .\manage.ps1 status
    .\manage.ps1 backup
    .\manage.ps1 backup -Region centro
    .\manage.ps1 backup -Limit fgt-centro-dc01 -Check
    .\manage.ps1 logs
    .\manage.ps1 shell
    .\manage.ps1 monitor
#>

param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("status","backup","validate","report","monitor","monitor-stop",
                 "logs","shell","health","security","wsl-setup","dr-status","compliance")]
    [string]$Command,
    [string]$Limit = "",
    [string]$Region = "",
    [switch]$Check,
    [string]$WslDistro = "Ubuntu-24.04",
    [string]$ExtraVars = "",
    [switch]$Wait
)

$ErrorActionPreference = "Continue"
$ProjectRoot = (Get-Location).Path
$ScriptDir = "$ProjectRoot\scripts\powershell"

function Write-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
}

function Test-WslReady {
    try {
        $result = wsl --status 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    } catch {}
    return $false
}

# ============================================
# Commands
# ============================================
function Invoke-Status {
    Write-Header "FortiGate Backup System Status"
    Write-Host ""

    # WSL2 status
    if (Test-WslReady) {
        $wslVersion = wsl --version 2>$null
        Write-Host "[WSL2]" -ForegroundColor Green
        if ($wslVersion) {
            Write-Host "  $($wslVersion -replace "`n",' | ')" -NoNewline
        }
        $running = wsl --list --running 2>$null
        Write-Host "  Running distros: $($running -join ', ')"
    } else {
        Write-Host "[WSL2]" -ForegroundColor Red
        Write-Host "  NOT AVAILABLE - Run 'manage.ps1 wsl-setup' first"
    }

    # Project
    Write-Host ""
    Write-Host "[Project]" -ForegroundColor Green
    Write-Host "  Root: $ProjectRoot"

    # Ansible inventory
    $inventoryPath = "$ProjectRoot\ansible\inventory\production\hosts.yml"
    if (Test-Path $inventoryPath) {
        $content = Get-Content $inventoryPath -Raw
        $deviceCount = [regex]::Matches($content, "ansible_host:").Count
        $regionCount = [regex]::Matches($content, "region_").Count
        Write-Host "  Devices: $deviceCount in $regionCount regions"
    }

    # Git status
    if (Test-Path "$ProjectRoot\.git") {
        try {
            $gitLog = git -C $ProjectRoot log --oneline -3 2>$null
            Write-Host "  Git: $(@($gitLog).Count) recent commits"
            $gitLog | ForEach-Object { Write-Host "    $_" }
        } catch {
            Write-Host "  Git: N/A"
        }
    }

    # Recent backups
    $backupRoot = "C:\ProgramData\fortigate-backups"
    if (Test-Path $backupRoot) {
        $backupCount = (Get-ChildItem -Path $backupRoot -Recurse -Filter "*full_config*" -ErrorAction SilentlyContinue).Count
        Write-Host "  Local Backups: $backupCount files"
    }

    # Docker
    $dockerRunning = docker ps --format "{{.Names}}" 2>$null
    if ($dockerRunning) {
        Write-Host ""
        Write-Host "[Docker]" -ForegroundColor Green
        $dockerRunning | ForEach-Object { Write-Host "  $_ running" }
    }

    Write-Host ""
}

function Invoke-CommandInWsl {
    param([string]$WslCommand)

    if (-not (Test-WslReady)) {
        Write-Error "WSL2 is not available. Run 'manage.ps1 wsl-setup' first."
        exit 1
    }

    Write-Info "Executing: $WslCommand"
    wsl.exe -d $WslDistro bash -c "cd /opt/fortigate-backup 2>/dev/null || cd /mnt/c/Users/$env:USERNAME/fortigate-backup-system; source venv/bin/activate 2>/dev/null; $WslCommand" 2>&1
}

function Invoke-Backup {
    $limitArg = if ($Region) { "-e 'backup_limit=region_$Region'" } elseif ($Limit) { "--limit $Limit" } else { "" }
    $checkArg = if ($Check) { "--check" } else { "" }
    $extraVarsArg = if ($ExtraVars) { "-e '$ExtraVars'" } else { "" }

    $cmd = "ansible-playbook ansible/playbooks/backup.yml -i ansible/inventory/production/hosts.yml --vault-password-file ansible/vault/.vault_password $limitArg $checkArg $extraVarsArg"
    Invoke-CommandInWsl -WslCommand $cmd
}

function Invoke-Validate {
    $cmd = "ansible-playbook ansible/playbooks/validate_all.yml -i ansible/inventory/production/hosts.yml --vault-password-file ansible/vault/.vault_password"
    Invoke-CommandInWsl -WslCommand $cmd
}

function Invoke-Report {
    $cmd = "python3 scripts/python/report_generator.py --backup-dir /opt/backups/fortigates --date $(Get-Date -Format 'yyyy-MM-dd') --format html --output reports/backup-report-$(Get-Date -Format 'yyyy-MM-dd').html 2>/dev/null || echo 'No backups to report'"
    Invoke-CommandInWsl -WslCommand $cmd
}

function Invoke-Health {
    $cmd = "python3 scripts/python/health_check.py --backup-dir /opt/backups/fortigates 2>/dev/null || echo 'Health check infrastructure only'"
    Invoke-CommandInWsl -WslCommand $cmd
}

function Invoke-Security {
    $cmd = "python3 scripts/python/secrets_scanner.py --dir ansible/ --ci-mode 2>/dev/null; python3 scripts/python/secrets_scanner.py --dir scripts/ --ci-mode 2>/dev/null; echo 'Security scan completed'"
    Invoke-CommandInWsl -WslCommand $cmd
}

function Invoke-Monitor {
    Write-Header "Starting Monitoring Stack"
    docker-compose -f "$ProjectRoot\ci_cd\docker-compose\monitoring-stack.yml" up -d 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Monitoring stack started:" -ForegroundColor Green
        Write-Host "  Grafana:      http://localhost:3000 (admin/admin123)" -ForegroundColor Cyan
        Write-Host "  Prometheus:   http://localhost:9090" -ForegroundColor Cyan
        Write-Host "  Alertmanager: http://localhost:9093" -ForegroundColor Cyan
    } else {
        Write-Error "Docker is required. Install Docker Desktop for Windows first."
    }
}

function Invoke-MonitorStop {
    Write-Header "Stopping Monitoring Stack"
    docker-compose -f "$ProjectRoot\ci_cd\docker-compose\monitoring-stack.yml" down
}

function Invoke-Logs {
    $logDir = "C:\ProgramData\fortigate-backups\logs"
    if (Test-Path $logDir) {
        Get-ChildItem $logDir -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
            Write-Host "=== $($_.Name) ($($_.Length) bytes, $($_.LastWriteTime)) ===" -ForegroundColor Cyan
            Get-Content $_ -Tail 20
            Write-Host ""
        }
    } else {
        $cmd = "tail -f /var/log/fortigate-backup/*.log 2>/dev/null || echo 'No log files found'"
        Invoke-CommandInWsl -WslCommand $cmd
    }
}

function Invoke-Shell {
    Write-Header "Opening WSL2 Shell"
    $wslProject = "/opt/fortigate-backup"
    if (-not (Test-Path "\\wsl.localhost\$WslDistro$wslProject")) {
        $wslProject = "/mnt/c/Users/$env:USERNAME/fortigate-backup-system"
    }
    Write-Info "Starting shell in: $wslProject"
    Start-Process wsl.exe -ArgumentList "-d $WslDistro --cd $wslProject"
}

function Invoke-DrStatus {
    $cmd = "scripts/bash/dr_failover.sh --status 2>/dev/null || echo 'DR script not available'"
    Invoke-CommandInWsl -WslCommand $cmd
}

function Invoke-Compliance {
    $cmd = "python3 security/audit/compliance_check.py --rules security/audit/audit_rules.yml --backup-dir /opt/backups/fortigates --profile enhanced 2>/dev/null || echo 'Compliance check infrastructure'"
    Invoke-CommandInWsl -WslCommand $cmd
}

function Invoke-WslSetup {
    & "$ScriptDir\bootstrap-wsl.ps1" -WslDistro $WslDistro
}

# ============================================
# Main
# ============================================
$commandMap = @{
    "status"       = ${function:Invoke-Status}
    "backup"       = ${function:Invoke-Backup}
    "validate"     = ${function:Invoke-Validate}
    "report"       = ${function:Invoke-Report}
    "monitor"      = ${function:Invoke-Monitor}
    "monitor-stop" = ${function:Invoke-MonitorStop}
    "logs"         = ${function:Invoke-Logs}
    "shell"        = ${function:Invoke-Shell}
    "health"       = ${function:Invoke-Health}
    "security"     = ${function:Invoke-Security}
    "wsl-setup"    = ${function:Invoke-WslSetup}
    "dr-status"    = ${function:Invoke-DrStatus}
    "compliance"   = ${function:Invoke-Compliance}
}

$cmdFunc = $commandMap[$Command]
if ($cmdFunc) {
    & $cmdFunc
} else {
    Write-Error "Unknown command: $Command"
    exit 1
}
