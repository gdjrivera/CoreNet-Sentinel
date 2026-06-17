<#
.SYNOPSIS
    FortiGate Backup System - WSL2 Bootstrap for Windows
.DESCRIPTION
    Complete setup of the backup infrastructure from Windows using WSL2.
    Detects WSL2, installs if needed, configures Ubuntu, mounts project,
    installs dependencies, and validates the environment.

.PARAMETER WslDistro
    WSL2 distribution name (default: Ubuntu-24.04)
.PARAMETER WslUser
    Default WSL2 user (default: backup-admin)
.PARAMETER ProjectPath
    Path to project root (default: current directory)
.PARAMETER SshKeyPath
    Path to SSH key to copy into WSL2
.PARAMETER NoInstallWsl
    Skip WSL2 installation check
.PARAMETER OnlyValidate
    Only validate existing setup without making changes

.EXAMPLE
    .\bootstrap-wsl.ps1

.EXAMPLE
    .\bootstrap-wsl.ps1 -WslDistro Ubuntu-22.04 -WslUser netadmin -NoInstallWsl

.EXAMPLE
    .\bootstrap-wsl.ps1 -OnlyValidate
#>

param(
    [string]$WslDistro = "Ubuntu-24.04",
    [string]$WslUser = "backup-admin",
    [string]$ProjectPath = (Get-Location).Path,
    [string]$SshKeyPath = "$env:USERPROFILE\.ssh\id_ed25519",
    [switch]$NoInstallWsl,
    [switch]$OnlyValidate
)

$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "FortiGate Backup - WSL2 Bootstrap"

# Colors via Write-Host
$CInfo = "Cyan"
$COk = "Green"
$CWarn = "Yellow"
$CErr = "Red"

function Write-Info  { Write-Host "[INFO]  $args" -ForegroundColor $CInfo }
function Write-Ok    { Write-Host "[OK]    $args" -ForegroundColor $COk }
function Write-Warn  { Write-Host "[WARN]  $args" -ForegroundColor $CWarn }
function Write-Error { Write-Host "[ERROR] $args" -ForegroundColor $CErr }

# ============================================
# Helper Functions
# ============================================
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WSL2Installed {
    try {
        $version = wsl --version 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Test-WSLDistroExists {
    param([string]$Distro)
    $distros = wsl --list --quiet 2>$null
    return $distros -match $Distro
}

function Test-WSL2Default {
    $status = wsl --status 2>$null
    return $status -match "Default Version: 2"
}

function Get-WslHome {
    $user = wsl.exe -d $WslDistro -u $WslUser bash -c 'echo $HOME' 2>$null
    return $user.Trim()
}

function Invoke-Wsl {
    param([string]$Command, [switch]$AsRoot)
    if ($AsRoot) {
        wsl.exe -d $WslDistro -u root bash -c "$Command"
    } else {
        wsl.exe -d $WslDistro -u $WslUser bash -c "$Command"
    }
}

function Get-WslExitCode {
    return $LASTEXITCODE
}

function ConvertTo-WslPath {
    param([string]$WindowsPath)
    $result = wsl.exe -d $WslDistro -u $WslUser bash -c "wslpath '$WindowsPath'" 2>$null
    return $result.Trim()
}

# ============================================
# Validation Steps
# ============================================
function Step-CheckOS {
    Write-Info "Checking operating system..."

    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    if ($osInfo.Caption -match "Windows") {
        Write-Ok "Windows detected: $($osInfo.Caption)"
        Write-Ok "Build: $($osInfo.BuildNumber)"

        $build = [int]$osInfo.BuildNumber
        if ($build -lt 19041) {
            Write-Error "WSL2 requires Windows 10 build 19041+ (20H1). Your build: $build"
            Write-Info "Update Windows or enable WSL2 manually: https://aka.ms/wsl2"
            return $false
        }
        return $true
    } else {
        Write-Error "This script is designed for Windows with WSL2"
        return $false
    }
}

function Step-CheckAdmin {
    Write-Info "Checking administrator privileges..."

    if (-not (Test-Administrator)) {
        Write-Warn "Not running as Administrator. Some operations may fail."
        Write-Warn "Right-click PowerShell and select 'Run as Administrator'"
        Write-Warn "Continuing with limited privileges..."
    } else {
        Write-Ok "Running as Administrator"
    }
    return $true
}

function Step-InstallWSL2 {
    if ($NoInstallWsl) {
        Write-Info "Skipping WSL2 installation (flag set)"
        return $true
    }

    Write-Info "Checking WSL2 installation..."

    if (Test-WSL2Installed) {
        Write-Ok "WSL2 is already installed"

        $version = wsl --version 2>$null
        if ($version) {
            Write-Ok "WSL version: $version"
        }

        if (-not (Test-WSL2Default)) {
            Write-Warn "WSL2 is not set as default. Configuring..."
            wsl --set-default-version 2
            Write-Ok "WSL2 set as default version"
        }
        return $true
    }

    Write-Info "Installing WSL2..."
    Write-Info "This will enable the Windows Subsystem for Linux feature..."

    try {
        # Enable WSL feature
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
        wsl --set-default-version 2

        Write-Ok "WSL2 installed. Please reboot and re-run this script."
        Write-Warn "REBOOT REQUIRED"
        return $false  # Needs reboot
    } catch {
        Write-Error "Failed to install WSL2: $_"
        Write-Info "Install manually: https://learn.microsoft.com/en-us/windows/wsl/install"
        return $false
    }
}

function Step-InstallDistro {
    Write-Info "Checking WSL2 distribution '$WslDistro'..."

    if (Test-WSLDistroExists -Distro $WslDistro) {
        Write-Ok "Distribution '$WslDistro' is already installed"

        # Ensure it's WSL2
        wsl --set-version $WslDistro 2 2>$null
        Write-Ok "Distribution set to WSL2"

        return $true
    }

    Write-Info "Installing distribution '$WslDistro'..."
    Write-Info "This will download from the Microsoft Store..."

    try {
        wsl --install -d $WslDistro
        Write-Warn "WSL distribution installed. Follow the Ubuntu setup prompts."
        Write-Warn "Create a default UNIX user when prompted, then re-run this script."
        return $false
    } catch {
        Write-Error "Failed to install distribution: $_"
        Write-Info "Try: wsl --install -d $WslDistro"
        return $false
    }
}

function Step-CreateWslUser {
    Write-Info "Checking WSL user '$WslUser'..."

    $exists = Invoke-Wsl -Command "id -u $WslUser 2>/dev/null || echo 'NOT_FOUND'"
    $exitCode = Get-WslExitCode

    if ($exists.Trim() -ne "NOT_FOUND") {
        Write-Ok "User '$WslUser' exists in WSL2"
        return $true
    }

    Write-Info "Creating user '$WslUser' in WSL2..."
    Invoke-Wsl -AsRoot -Command "useradd -m -s /bin/bash -G sudo $WslUser && echo '$WslUser ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/$WslUser"
    if ($(Get-WslExitCode) -eq 0) {
        Write-Ok "User '$WslUser' created with passwordless sudo"
        Invoke-Wsl -AsRoot -Command "chsh -s /bin/bash $WslUser"
        return $true
    } else {
        Write-Error "Failed to create user"
        return $false
    }
}

function Step-MountProject {
    Write-Info "Mounting project in WSL2..."

    $wslProjectRoot = "/opt/fortigate-backup"
    $windowsPath = $ProjectPath.Replace("\", "/").Replace("C:", "/mnt/c")

    # Convert to proper WSL path
    if ($ProjectPath -match "^[A-Za-z]:") {
        $drive = $ProjectPath.Substring(0,1).ToLower()
        $rest = $ProjectPath.Substring(3).Replace("\", "/")
        $wslWindowsPath = "/mnt/$drive/$rest"
    } else {
        $wslWindowsPath = $ProjectPath
    }

    Write-Info "Windows path: $ProjectPath"
    Write-Info "WSL mount point: $wslProjectRoot"
    Write-Info "WSL source: $wslWindowsPath"

    # Create symlink
    Invoke-Wsl -Command "ln -sfn '$wslWindowsPath' '$wslProjectRoot' 2>/dev/null || sudo ln -sfn '$wslWindowsPath' '$wslProjectRoot'"
    Invoke-Wsl -Command "ls -la '$wslProjectRoot' | head -20"

    if ($(Get-WslExitCode) -eq 0) {
        Write-Ok "Project mounted at $wslProjectRoot -> $wslWindowsPath"
    } else {
        Write-Warn "Symlink failed. Project will be accessed directly via $wslWindowsPath"
    }
}

function Step-CopySshKey {
    Write-Info "Setting up SSH keys in WSL2..."

    # Check if SSH key exists on Windows
    if (Test-Path $SshKeyPath) {
        Write-Ok "Windows SSH key found: $SshKeyPath"
        $wslSshDir = Invoke-Wsl -Command "echo \$HOME/.ssh" | Out-String
        $wslSshDir = $wslSshDir.Trim()

        # Copy key
        $keyContent = Get-Content $SshKeyPath -Raw
        $pubKeyContent = Get-Content "$SshKeyPath.pub" -Raw

        Invoke-Wsl -Command "mkdir -p $wslSshDir && chmod 700 $wslSshDir"
        Invoke-Wsl -Command "cat >> $wslSshDir/id_ed25519" << EOF
$keyContent
EOF
        Invoke-Wsl -Command "cat >> $wslSshDir/id_ed25519.pub" << EOF
$pubKeyContent
EOF
        Invoke-Wsl -Command "chmod 600 $wslSshDir/id_ed25519 && chmod 644 $wslSshDir/id_ed25519.pub"

        Write-Ok "SSH key copied to WSL2"
    } else {
        Write-Warn "No SSH key found at $SshKeyPath"
        Write-Info "Generating new SSH key in WSL2..."
        Invoke-Wsl -Command "ssh-keygen -t ed25519 -a 100 -f \$HOME/.ssh/fortigate-backup-key -N '' -C 'fortigate-backup@wsl'"
        Write-Ok "New SSH key generated in WSL2"
    }
}

function Step-InstallDependencies {
    Write-Info "Installing dependencies in WSL2..."

    $commands = @(
        "sudo apt-get update -qq",
        "sudo apt-get install -y -qq python3 python3-pip python3-venv git ansible-core openssh-client sshpass curl jq tree acl rsync",
        "python3 -m venv $wslProjectRoot/venv",
        "source $wslProjectRoot/venv/bin/activate && pip install --quiet -r $wslProjectRoot/requirements.txt",
        "source $wslProjectRoot/venv/bin/activate && ansible-galaxy collection install fortinet.fortios community.network -q"
    )

    foreach ($cmd in $commands) {
        Write-Info "  Running: $cmd"
        Invoke-Wsl -Command "$cmd"
        if ($(Get-WslExitCode) -ne 0) {
            Write-Warn "Command returned non-zero: $cmd"
        }
    }

    Write-Ok "Dependencies installed in WSL2"
}

function Step-ValidateSetup {
    Write-Info "Validating WSL2 setup..."
    $errors = 0

    # Check WSL2 is running
    $wslRunning = wsl --list --running 2>$null
    if ($wslRunning -match $WslDistro) {
        Write-Ok "WSL2 distribution '$WslDistro' is running"
    } else {
        Write-Warn "WSL2 distribution '$WslDistro' is not running. Start with: wsl -d $WslDistro"
        $errors++
    }

    # Check Python
    $pythonVer = Invoke-Wsl -Command "python3 --version"
    if ($pythonVer -match "Python 3") {
        Write-Ok "Python: $($pythonVer.Trim())"
    } else {
        Write-Warn "Python not found in WSL2"
        $errors++
    }

    # Check Ansible
    $ansibleVer = Invoke-Wsl -Command "source $wslProjectRoot/venv/bin/activate && ansible --version | head -1"
    if ($ansibleVer -match "ansible") {
        Write-Ok "Ansible: $($ansibleVer.Trim())"
    } else {
        Write-Warn "Ansible not found"
        $errors++
    }

    # Check project mount
    $projectCheck = Invoke-Wsl -Command "ls $wslProjectRoot/ansible/playbooks/backup.yml 2>/dev/null && echo 'OK' || echo 'NOT_FOUND'"
    if ($projectCheck.Trim() -eq "OK") {
        Write-Ok "Project files accessible in WSL2"
    } else {
        Write-Warn "Project not mounted correctly at $wslProjectRoot"
        $errors++
    }

    # Check Git
    $gitVer = Invoke-Wsl -Command "git --version"
    if ($gitVer -match "git") {
        Write-Ok "Git: $($gitVer.Trim())"
    } else {
        Write-Warn "Git not found"
        $errors++
    }

    if ($errors -eq 0) {
        Write-Ok "All validations passed!"
        return $true
    } else {
        Write-Warn "$errors validation(s) failed"
        return ($errors -eq 0)
    }
}

# ============================================
# SSH Config Generator
# ============================================
function Step-CreateSshConfig {
    Write-Info "Creating SSH configuration in WSL2..."

    $sshConfig = @'
Host bastion
    HostName bastion.internal.local
    User backup-admin
    Port 22
    IdentityFile ~/.ssh/fortigate-backup-key
    ForwardAgent no
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking accept-new

Host 10.*.*.*
    ProxyJump bastion
    IdentityFile ~/.ssh/fortigate-backup-key
    User admin
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
    ServerAliveInterval 30
    ServerAliveCountMax 3

Host github.com
    IdentityFile ~/.ssh/fortigate-backup-key
    StrictHostKeyChecking accept-new

Host gitlab.internal.local
    IdentityFile ~/.ssh/fortigate-backup-key
    StrictHostKeyChecking accept-new
'@

    Invoke-Wsl -Command "mkdir -p \$HOME/.ssh && chmod 700 \$HOME/.ssh"
    Invoke-Wsl -Command "cat > \$HOME/.ssh/config" << 'SSHCONFIG'
$sshConfig
SSHCONFIG
    Invoke-Wsl -Command "chmod 600 \$HOME/.ssh/config"

    Write-Ok "SSH configuration created in WSL2"
}

function Step-ShowBanner {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor $CInfo
    Write-Host " FortiGate Backup System - WSL2 Bootstrap" -ForegroundColor $CInfo
    Write-Host "============================================" -ForegroundColor $CInfo
    Write-Host " Project: $ProjectPath" -ForegroundColor $CInfo
    Write-Host " WSL Distro: $WslDistro" -ForegroundColor $CInfo
    Write-Host " WSL User: $WslUser" -ForegroundColor $CInfo
    Write-Host " Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor $CInfo
    Write-Host "============================================" -ForegroundColor $CInfo
    Write-Host ""
}

# ============================================
# Final Instructions
# ============================================
function Show-FinalInstructions {
    $wslProject = "/opt/fortigate-backup"
    $wslHome = Invoke-Wsl -Command "echo \$HOME" | Out-String
    $wslHome = $wslHome.Trim()

    Write-Host ""
    Write-Host "============================================" -ForegroundColor $COk
    Write-Host " WSL2 Setup Complete!" -ForegroundColor $COk
    Write-Host "============================================" -ForegroundColor $COk
    Write-Host ""
    Write-Host " Quick Commands:" -ForegroundColor $CInfo
    Write-Host "  Enter WSL2:                wsl -d $WslDistro"
    Write-Host "  Go to project:             cd $wslProject"
    Write-Host "  Activate venv:             source $wslProject/venv/bin/activate"
    Write-Host ""
    Write-Host " One-liner to start working:" -ForegroundColor $CInfo
    Write-Host "  wsl -d $WslDistro -u $WslUser -- cd $wslProject && source venv/bin/activate && bash"
    Write-Host ""
    Write-Host " Run Ansible from PowerShell:" -ForegroundColor $CInfo
    Write-Host "  .\scripts\powershell\run-ansible.ps1 -Playbook backup.yml"
    Write-Host "  .\scripts\powershell\run-ansible.ps1 -Playbook backup.yml -Limit region_centro"
    Write-Host ""
    Write-Host " Make targets (inside WSL2):" -ForegroundColor $CInfo
    Write-Host "  make setup         - Full bootstrap"
    Write-Host "  make backup        - Run backup"
    Write-Host "  make backup-check  - Dry-run"
    Write-Host "  make validate      - Validate configs"
    Write-Host "  make report        - Generate HTML report"
    Write-Host "  make monitor       - Start monitoring stack"
    Write-Host ""
    Write-Host " Next Steps:" -ForegroundColor $CWarn
    Write-Host "  1. Edit vault credentials:"
    Write-Host "     wsl -d $WslDistro -u $WslUser"
    Write-Host "     cd $wslProject && source venv/bin/activate"
    Write-Host "     ansible-vault edit ansible/vault/vault.yml"
    Write-Host ""
    Write-Host "  2. Test connectivity:"
    Write-Host "     ansible all -i ansible/inventory/staging/hosts.yml -m ping"
    Write-Host ""
    Write-Host "  3. Run first backup:"
    Write-Host "     ansible-playbook ansible/playbooks/backup.yml --check"
    Write-Host "     ansible-playbook ansible/playbooks/backup.yml"
    Write-Host ""
    Write-Host "============================================" -ForegroundColor $COk
}

# ============================================
# Main
# ============================================
function Main {
    Step-ShowBanner

    # Step 1: Check OS
    if (-not (Step-CheckOS)) { return }

    # Step 2: Check admin
    Step-CheckAdmin

    # Step 3: Check/Install WSL2
    if (-not (Step-InstallWSL2)) { return }

    # Step 4: Check/Install distro
    if (-not (Step-InstallDistro)) { return }

    # Step 5: Ensure WSL2 distro is running
    wsl -d $WslDistro -u root echo "WSL2 is ready" 2>$null

    if ($OnlyValidate) {
        Step-ValidateSetup
        return
    }

    # Step 6: Create user
    Step-CreateWslUser

    # Step 7: Mount project
    Step-MountProject

    # Step 8: Copy SSH keys
    Step-CopySshKey

    # Step 9: Create SSH config
    Step-CreateSshConfig

    # Step 10: Install dependencies
    Step-InstallDependencies

    # Step 11: Validate
    Step-ValidateSetup

    # Step 12: Show instructions
    Show-FinalInstructions
}

Main
