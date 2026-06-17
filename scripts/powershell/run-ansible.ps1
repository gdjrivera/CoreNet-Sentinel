<#
.SYNOPSIS
    Run Ansible playbooks from Windows PowerShell via WSL2
.DESCRIPTION
    Executes Ansible commands inside WSL2 seamlessly.
    Handles path conversion, venv activation, and vault passwords.

.PARAMETER Playbook
    Playbook name or path (relative to ansible/playbooks/)
.PARAMETER Inventory
    Inventory file (default: ansible/inventory/production/hosts.yml)
.PARAMETER Limit
    Host limit pattern (e.g., region_centro, fgt-centro-dc01)
.PARAMETER ExtraVars
    Extra variables as string (e.g., "backup_method=api notify_on_failure=true")
.PARAMETER VaultPass
    Vault password file path
.PARAMETER Check
    Run in check (dry-run) mode
.PARAMETER Verbose
    Increase verbosity (-v, -vv, -vvv)
.PARAMETER Tags
    Run specific tags only
.PARAMETER WslDistro
    WSL2 distribution name
.PARAMETER Task
    Run an ad-hoc ansible task instead of playbook

.EXAMPLE
    .\run-ansible.ps1 -Playbook backup.yml
    .\run-ansible.ps1 -Playbook backup.yml -Limit region_centro -Check
    .\run-ansible.ps1 -Playbook restore.yml -ExtraVars "restore_version=20250101_020000"
    .\run-ansible.ps1 -Task "ping" -Limit fgt-centro-dc01
    .\run-ansible.ps1 -Playbook backup.yml -Verbose -Tags backup
#>

param(
    [Parameter(ParameterSetName="Playbook")]
    [string]$Playbook,

    [Parameter(ParameterSetName="Adhoc")]
    [string]$Task,

    [string]$Inventory = "ansible/inventory/production/hosts.yml",
    [string]$Limit = "",
    [string]$ExtraVars = "",
    [string]$VaultPass = "",
    [switch]$Check,
    [ValidateSet("","-v","-vv","-vvv")]
    [string]$Verbose = "",
    [string]$Tags = "",
    [string]$WslDistro = "Ubuntu-24.04",
    [string]$WslUser = "backup-admin"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Get-Location).Path
$WslProject = "/opt/fortigate-backup"

$CInfo = "Cyan"
$COk = "Green"
$CWarn = "Yellow"
$CErr = "Red"

function Write-Info  { Write-Host "[INFO]  $args" -ForegroundColor $CInfo }
function Write-Ok    { Write-Host "[OK]    $args" -ForegroundColor $COk }
function Write-Warn  { Write-Host "[WARN]  $args" -ForegroundColor $CWarn }
function Write-Error { Write-Host "[ERROR] $args" -ForegroundColor $CErr }

function Invoke-Wsl {
    param([string]$Command)
    $result = wsl.exe -d $WslDistro -u $WslUser bash -c "$Command" 2>&1
    $global:LASTEXITCODE = $LASTEXITCODE
    return $result
}

# ============================================
# Main Execution
# ============================================
function Main {
    # Validate WSL2 is available
    $wslCheck = wsl --status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "WSL2 is not available. Run .\scripts\powershell\bootstrap-wsl.ps1 first"
        exit 1
    }

    # Check distro is running
    $distroRunning = wsl --list --running 2>$null
    if ($distroRunning -notmatch $WslDistro) {
        Write-Info "Starting WSL2 distribution '$WslDistro'..."
        wsl -d $WslDistro echo "started"
    }

    # Check project mount
    $projectCheck = Invoke-Wsl "ls $WslProject/ansible 2>/dev/null && echo 'OK' || echo 'NOT_FOUND'"
    if ($projectCheck.Trim() -ne "OK") {
        # Fallback: use direct /mnt path
        $drive = $ProjectRoot.Substring(0,1).ToLower()
        $rest = $ProjectRoot.Substring(3).Replace("\", "/")
        $WslProject = "/mnt/$drive/$rest"
        Write-Warn "Project not mounted at /opt/fortigate-backup"
        Write-Info "Using direct path: $WslProject"
    }

    # Build command
    $cmd = "cd $WslProject && source venv/bin/activate && "

    if ($PSCmdlet.ParameterSetName -eq "Playbook") {
        # Resolve playbook path
        $playbookPath = $Playbook
        if (-not ($Playbook -match "^/|^ansible/")) {
            $playbookPath = "ansible/playbooks/$Playbook"
        }
        if (-not ($Playbook -match "\.yml$")) {
            $playbookPath += ".yml"
        }

        if (-not (Test-Path "$ProjectRoot/$playbookPath") -and -not ($playbookPath -match "^/")) {
            Write-Error "Playbook not found: $playbookPath"
            Write-Info "Looked in: $ProjectRoot/$playbookPath"
            exit 1
        }

        $cmd += "ansible-playbook $playbookPath"
    } else {
        $cmd += "ansible all"
    }

    # Add inventory
    if ($Inventory) {
        $invPath = $Inventory
        if (-not ($invPath -match "^-i|^/")) {
            $invPath = "-i $Inventory"
        }
        $cmd += " $invPath"
    }

    # Add vault password
    if ($VaultPass -and (Test-Path $VaultPass)) {
        $cmd += " --vault-password-file $VaultPass"
    } else {
        $vaultDefault = "$ProjectRoot\ansible\vault\.vault_password"
        if (Test-Path $vaultDefault) {
            $cmd += " --vault-password-file ansible/vault/.vault_password"
        }
    }

    # Add limit
    if ($Limit) { $cmd += " --limit $Limit" }

    # Add extra vars
    if ($ExtraVars) { $cmd += " -e '$ExtraVars'" }

    # Add check mode
    if ($Check) { $cmd += " --check" }

    # Add verbosity
    if ($Verbose) { $cmd += " $Verbose" }

    # Add tags
    if ($Tags) { $cmd += " --tags $Tags" }

    # For ad-hoc tasks
    if ($PSCmdlet.ParameterSetName -eq "Adhoc" -and $Task) {
        $cmd += " -m $Task"
    }

    # Display command
    Write-Host ""
    Write-Info "Executing in WSL2 ($WslDistro):"
    Write-Host "  $cmd" -ForegroundColor $CInfo
    Write-Host ""

    # Confirm
    if (-not $Check) {
        Write-Warn "Press Enter to continue or Ctrl+C to abort..."
        Read-Host | Out-Null
    }

    # Execute
    $startTime = Get-Date
    Write-Info "Started at: $($startTime.ToString('HH:mm:ss'))"

    # Run via WSL2
    $output = wsl.exe -d $WslDistro -u $WslUser bash -c "$cmd" 2>&1
    $exitCode = $LASTEXITCODE

    $endTime = Get-Date
    $duration = $endTime - $startTime

    # Display output
    $output | ForEach-Object { Write-Host $_ }

    Write-Host ""
    if ($exitCode -eq 0) {
        Write-Ok "Completed successfully in $($duration.TotalSeconds.ToString('F1'))s"
    } else {
        Write-Error "Failed with exit code $exitCode in $($duration.TotalSeconds.ToString('F1'))s"
    }

    exit $exitCode
}

Main
