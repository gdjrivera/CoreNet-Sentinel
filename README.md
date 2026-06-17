# FortiGate Backup System

Sistema centralizado de respaldo automatico para configuraciones de FortiGate.
11+ dispositivos en 4 regiones, backup cada 6 horas, validacion, hash chain, control de versiones cifrado, monitoreo Prometheus/Grafana, DR failover.

---

## Tabla de Contenidos

1. [Arquitectura](#arquitectura)
2. [Inventario de Dispositivos](#inventario-de-dispositivos)
3. [Requisitos Tecnicos](#requisitos-tecnicos)
4. [Instalacion](#instalacion)
   - [Linux](#en-linux)
   - [Windows WSL2](#en-windows-wsl2)
5. [Configuracion](#configuracion)
   - [Ansible Vault](#ansible-vault)
   - [Inventory](#inventory)
   - [Group Vars](#group-vars)
   - [Makefile](#makefile)
6. [Playbooks Detallados](#playbooks-detallados)
7. [Roles Ansible](#roles-ansible)
8. [Scripts Python](#scripts-python)
9. [Scripts Bash](#scripts-bash)
10. [Scripts PowerShell](#scripts-powershell)
11. [Monitoreo](#monitoreo)
12. [Seguridad](#seguridad)
13. [CI/CD](#cicd)
14. [DR Failover](#dr-failover)
15. [Testing](#testing)
16. [Uso Diario](#uso-diario)
17. [Preguntas Frecuentes](#preguntas-frecuentes)
18. [Problemas Conocidos](#problemas-conocidos)

---

## Arquitectura

### Stack tecnologico

| Componente | Tecnologia | Version | Proposito |
|------------|-----------|---------|-----------|
| Orquestacion | Ansible | 2.15+ | Ejecutar playbooks de backup/restore/validate |
| Scheduler | AWX / cron | - | Programar backups cada 6h |
| Control de versiones | Git + git-crypt | 2.30+ | Historial de cambios cifrado |
| Validacion | Python | 3.10+ | 15 checks de seguridad y sintaxis |
| Hash chain | Python (hashlib SHA-256) | - | Deteccion de manipulacion (Merkle DAG) |
| Secreto scanning | Python (regex + entropia) | - | 20+ patrones de passwords/keys |
| Metadatos | SQLite / PostgreSQL | - | Registro de auditoria y compliance |
| Reportes | Python (Jinja2) | - | HTML/JSON diarios y por rango |
| Monitoreo | Prometheus + Grafana | - | Metricas en tiempo real, alertas |
| Notificaciones | Slack / Email / PagerDuty | - | Alertas por canal segun criticidad |
| Cifrado | Ansible Vault + git-crypt | AES-256 | Credenciales y repo cifrados |
| Backup frio | S3 / MinIO (Object Lock) | - | Backups inmutables 365 dias |
| CI/CD | GitLab CI / GitHub Actions | - | Pipeline automatizado de validacion |

### Diagrama de red

```
    [Internet]
        |
    [Bastion Host :22]   <-- Unico punto de entrada SSH
        |
    [Servidor Ansible]   <-- Aqui corre todo el sistema
        |
    +----+----+----+----+
    |    |    |    |    |
  [CEN] [NOR] [SUR] [ORI]   <- 4 regiones
    |    |    |    |
  DC-01 DC-01 DC-01 DC-01   <- Primary (API)
  DC-02      SUC-01 SUC-01  <- Secondary (API) / Edge (SSH)
  SUC-01                     <- Edge (SSH)
  SUC-02                     <- Edge (SSH)
```

### Protocolos y puertos

| Protocolo | Puerto | Origen | Destino | Proposito |
|-----------|--------|--------|---------|-----------|
| SSH | 22 | Servidor Ansible | FortiGates (edge) | Backup via CLI |
| HTTPS | 443 | Servidor Ansible | FortiGates (primary/secondary) | Backup via REST API |
| SSH | 22 | Servidor Ansible | Bastion host | Tunnel para staging |
| HTTPS | 443 | Servidor Ansible | GitLab/GitHub | Git push |
| HTTPS | 443 | Servidor Ansible | Slack / PagerDuty | Notificaciones |
| TCP | 9090 | Servidor Ansible | Prometheus | Metricas |
| TCP | 3000 | Admin | Grafana | Dashboards |

### Flujo de backup (tecnico)

```
[Hora: 02:00] AWX dispara job "FortiGate Full Backup"
    |
    v
[Ansible resuelve inventory] -> 11 hosts en 4 grupos regionales
    |                            forks=50, serial=10
    v
[Por cada FortiGate, en paralelo (10 a la vez)]:
    |
    +-- [Metodo SSH]: ansible.builtin.cli_command ->
    |     "show full-configuration" + "get system status" + "get system ha status"
    |     Output -> /opt/backups/{hostname}/{fecha}/{hora}_full_config.conf
    |     Metadata -> JSON con version firmware, serial, uptime, licencias
    |
    +-- [Metodo API]: ansible.builtin.uri ->
    |     GET /api/v2/monitor/system/config/backup
    |     Header: Authorization Bearer {api_key}
    |     Output -> mismo path que SSH
    |
    v
[Post-procesamiento] (por cada archivo):
    |
    +-- Validador (config_validator.py):
    |     15 checks: tamano minimo, secciones requeridas, { } balance,
    |     forbidden patterns, security posture, dual-CP con checksum
    |
    +-- Hash chain (hash_verifier.py):
    |     SHA-256 del archivo
    |     Encadena con hash anterior (Merkle DAG) -> .hash_chain.json
    |     Si el hash anterior no coincide -> tamper detected
    |
    +-- Secrets scanner (secrets_scanner.py):
    |     20+ regex para passwords, API keys, certs, tokens
    |     Analisis de entropia (shannon > 4.5 = probable secreto)
    |     Output SARIF para integracion con SIEM
    |
    v
[Git sync]:
    git add -> git commit -m "[backup] YYYY-MM-DD HH:MM - fgt-centro-dc01..."
    git tag backup-YYYYMMDD-HHMMSS
    git push (via SSH deploy key)
    |
    v
[Notificacion]:
    +-- Todo OK -> solo log interno
    +-- Warning (secreto detectado, config cambiada) -> Slack #network-backups
    +-- Error critical -> PagerDuty + Slack + Email
    |
    v
[Registro en BD]:
    metadata_logger.py -> SQLite / PostgreSQL
    Tablas: device_backups, audit_log, compliance_records, backup_summary
    |
    v
[Hora: 02:30] Backup completado. Proxima ejecucion: 08:00
```

---

## Inventario de Dispositivos

### Produccion (11 FortiGates) | Series genericas |

| Hostname | Region | Rol | IP | Modelo | Serie | Firmware | Metodo |
|----------|--------|-----|----|--------|-------|----------|--------|
| fgt-centro-dc01 | centro | primary | 10.1.1.1 | FG-100F | FG100F12345678 | v7.4.1 | API |
| fgt-centro-dc02 | centro | secondary | 10.1.1.2 | FG-60F | FG60F12345678 | v7.2.5 | API |
| fgt-centro-suc01 | centro | edge | 10.1.2.1 | FG-40F | FG40F12345678 | v7.0.3 | SSH |
| fgt-centro-suc02 | centro | edge | 10.1.2.2 | FG-30E | FG30E12345678 | v6.4.10 | SSH |
| fgt-norte-dc01 | norte | primary | 10.2.1.1 | FG-200F | FG200F12345678 | v7.4.1 | API |
| fgt-norte-dc02 | norte | secondary | 10.2.1.2 | FG-60F | FG60F87654321 | v7.2.5 | API |
| fgt-norte-suc01 | norte | edge | 10.2.2.1 | FG-40F | FG40F87654321 | v7.0.3 | SSH |
| fgt-sur-dc01 | sur | primary | 10.3.1.1 | FG-100F | FG100F87654321 | v7.4.0 | API |
| fgt-sur-suc01 | sur | edge | 10.3.2.1 | FG-30E | FG30E87654321 | v6.4.10 | SSH |
| fgt-oriente-dc01 | oriente | primary | 10.4.1.1 | FG-60F | FG60F11111111 | v7.2.5 | API |
| fgt-oriente-suc01 | oriente | edge | 10.4.2.1 | FG-40F | FG40F11111111 | v7.0.3 | SSH |

**Nota tecnica:** El metodo de backup se define por modelo. Los FG-100F/200F tienen REST API completa (v7.4+). Los FG-60F tienen API limitada (v7.2). Los FG-40F/30E solo tienen SSH (v7.0/v6.4). Ver `ansible/roles/backup_fortigate/vars/main.yml` para la matriz de compatibilidad.

### Staging (2 dispositivos)

| Hostname | IP | Proposito |
|----------|----|-----------|
| fgt-sandbox-01 | 192.168.100.1 | Pruebas de integracion |
| fgt-sandbox-02 | 192.168.100.2 | Pruebas de restore |

Los dispositivos de staging se conectan via bastion host. Ver `ansible/inventory/staging/hosts.yml`.

---

## Requisitos Tecnicos

### Hardware

| Recurso | Minimo (dev/test) | Recomendado (produccion) |
|---------|-------------------|-------------------------|
| CPU | 2 cores | 4+ cores |
| RAM | 4 GB | 8+ GB |
| Disco | 10 GB libres | 100+ GB SSD |
| Red | 100 Mbps | 1 Gbps |

### Software

| Paquete | Version min | Instalacion (Ubuntu/Debian) |
|---------|-------------|----------------------------|
| Python | 3.10 | `python3 python3-venv python3-pip` |
| Ansible | 2.15 | `pip install ansible` (en venv) |
| Git | 2.30 | `git` |
| OpenSSH | 8.0 | `openssh-client` |
| Docker | 24+ | `docker.io docker-compose-v2` (opcional) |
| make | - | `make` |
| curl | - | `curl` |
| rsync | - | `rsync` (para DR) |
| WSL2 | - | Windows 10 19041+ o Windows 11 |

### Colecciones de Ansible requeridas

```
ansible.builtin          (incluida en Ansible Core)
community.general        (para cli_command, ini_file)
community.crypto         (para openssh_keypair)
ansible.posix            (para autorized_key, mount)
```

Se instalan via: `ansible-galaxy collection install -r ansible/requirements.yml`

---

## Instalacion

### En Linux

```bash
# 1. Clonar
git clone <repo-url> fortigate-backup
cd fortigate-backup

# 2. Instalacion automatica (produccion)
#    Crea usuario backup-admin, instala paquetes, crea venv,
#    genera SSH keys, configura firewall, crea directorios,
#    copia vault password template
sudo make setup

#    Instalacion sin sudo (desarrollo local)
make setup-dev

# 3. Activar entorno virtual (cada sesion)
source venv/bin/activate

# 4. Configurar credenciales
#    NOTA: vault.yml ya existe con valores placeholder.
#    DEBES editarlo con tus credenciales reales:
ansible-vault edit ansible/vault/vault.yml

#    Valores a cambiar:
#    - vault_ansible_user: "backup-admin" (usuario SSH en FortiGates)
#    - vault_ssh_key_path: "~/.ssh/fortigate-backup-key"
#    - vault_fortigate_api_user: "api-backup"
#    - vault_fortigate_api_key: "<tu-api-key>"
#    - vault_bastion_host: "bastion.internal.local"
#    - vault_bastion_user: "jump-admin"
#    - vault_slack_webhook_url: "https://hooks.slack.com/services/..."
#    - vault_pagerduty_integration_key: "<tu-pagerduty-key>"
#    - vault_smtp_server: "smtp.internal.local"
#    - vault_smtp_port: 587
#    - vault_smtp_username: "backup-notify@internal.local"
#    - vault_smtp_password: "<smtp-password>"
#    - vault_s3_endpoint: "s3.internal.local"
#    - vault_s3_bucket: "fortigate-backups"
#    - vault_s3_access_key: "<s3-access-key>"
#    - vault_s3_secret_key: "<s3-secret-key>"
#    - vault_notification_email: "netops@internal.local"

# 5. Verificar conectividad con staging
ansible all -i ansible/inventory/staging/hosts.yml -m ping -v

# 6. Backup en modo simulacion
make backup-check
#    Revisar output: debe listar "ok" para cada dispositivo
#    Sin errores "UNREACHABLE" ni "FAILED"

# 7. Backup real
make backup

# 8. Ver resultado
make status
make report
```

### En Windows (WSL2)

WSL2 no es una MV pesada. Es una capa de compatibilidad nativa de Windows
que ejecuta el kernel de Linux directamente. Los backups corren en Linux,
pero el control es desde PowerShell.

```powershell
# ============ PRERREQUISITOS ============

# Windows 10 build 19041+ o Windows 11
# BIOS/UEFI con virtualizacion habilitada (VT-x/AMD-V)
# 8+ GB RAM recomendados

# Verificar compatibilidad:
systeminfo | findstr "Hyper-V"
# Debe aparecer: "Se requiere un hipervisor. Se ha detectado."

# ============ 1. INSTALACION WSL2 + SISTEMA ============

# PowerShell como ADMINISTRADOR
cd C:\Users\Stargroup\fortigate-backup-system

.\scripts\powershell\bootstrap-wsl.ps1

# El script hace TODO automaticamente (10-15 min):
#   Fase 1: Verifica Windows, activa WSL2, instala Ubuntu 24.04
#   Fase 2: Crea usuario backup-admin, password aleatorio
#   Fase 3: Monta C:\Users\Stargroup\fortigate-backup-system en WSL2
#   Fase 4: Instala Python 3.12, Ansible, Git, OpenSSH, make, rsync
#   Fase 5: Crea venv, activa, instala requirements
#   Fase 6: Instala colecciones Ansible (requirements.yml)
#   Fase 7: Genera SSH key ed25519
#   Fase 8: Crea directorios /opt/backups/fortigates
#   Fase 9: Copia .vault_password_template -> .vault_password
#   Fase 10: Valida todo (python --version, ansible --version, etc.)

# Posibles errores:
#   "No se pudo instalar WSL2" -> Activar manual:
#     dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux
#     dism.exe /online /enable-feature /featurename:VirtualMachinePlatform
#     wsl --set-default-version 2
#     wsl --install -d Ubuntu-24.04
#     Reiniciar y ejecutar bootstrap-wsl.ps1 de nuevo

#   "Error al crear usuario" -> WSL2 ya tiene un usuario. Hacer:
#     wsl -d Ubuntu-24.04
#     sudo usermod -aG sudo <tu-usuario>
#     exit

# ============ 2. CONFIGURAR CREDENCIALES ============

# Entrar a WSL2:
.\scripts\powershell\manage.ps1 shell

# Dentro de WSL2:
cd /opt/fortigate-backup
source venv/bin/activate
ansible-vault edit ansible/vault/vault.yml
# Editar credenciales reales
exit

# Alternativamente, editar desde Windows:
# El vault password esta en: ansible/vault/.vault_password
# Para editar con VSCode: code ansible/vault/vault.yml  (NO FUNCIONA, esta cifrado)
# Siempre usar: ansible-vault edit

# ============ 3. PROBAR CONEXION ============

.\scripts\powershell\run-ansible.ps1 -Playbook backup.yml -Check

# ============ 4. PRIMER BACKUP REAL ============

.\scripts\powershell\manage.ps1 backup

# ============ 5. VER RESULTADOS ============

.\scripts\powershell\manage.ps1 status
.\scripts\powershell\manage.ps1 report
```

**Nota:** La primera ejecucion de Ansible descarga collections y modulos. Puede tomar 2-3 minutos adicionales. No interrumpir.

---

## Configuracion

### Ansible Vault

Las credenciales se guardan cifradas con Ansible Vault (AES-256).

```bash
# Archivos:
ansible/vault/vault.yml          # Credenciales cifradas
ansible/vault/.vault_password    # Password del vault (NUNCA subir a Git)

# Comandos utiles:
ansible-vault view ansible/vault/vault.yml              # Ver contenido descifrado
ansible-vault edit ansible/vault/vault.yml              # Editar (abre $EDITOR)
ansible-vault encrypt ansible/vault/vault.yml           # Cifrar archivo
ansible-vault decrypt ansible/vault/vault.yml           # Descifrar (SOLO temporal)
ansible-vault rekey ansible/vault/vault.yml             # Cambiar password

# Rotacion de password del vault (cada 180 dias):
ansible-vault rekey ansible/vault/vault.yml
# Te pedira: Old password, New password, Confirm new password
# Luego actualizar ansible/vault/.vault_password con el nuevo password
```

**IMPORTANTE:**
- `.vault_password` esta en `.gitignore` - NUNCA subirlo a Git.
- Si pierdes el password del vault, NO podras recuperar las credenciales.
- Guardar una copia offline del password en gestor de passwords corporativo.
- El Makefile lee el password desde `ansible/vault/.vault_password` automaticamente.

### Inventory

```yaml
# ansible/inventory/production/hosts.yml (extracto)
all:
  children:
    region_centro:
      hosts:
        fgt-centro-dc01:
          ansible_host: 10.1.1.1
          fortigate_model: FG-100F
          fortigate_serial: FG100F12345678
          fortigate_firmware: v7.4.1
          fortigate_role: primary
          backup_method: api
          region: centro
          location: Santiago - DC01
        fgt-centro-suc01:
          ansible_host: 10.1.2.1
          fortigate_model: FG-40F
          fortigate_serial: FG40F12345678
          fortigate_firmware: v7.0.3
          fortigate_role: edge
          backup_method: ssh
          region: centro
          location: Santiago - Sucursal 1

    region_norte: { ... }
    region_sur: { ... }
    region_oriente: { ... }

  vars:
    ansible_user: "{{ vault_ansible_user }}"
    ansible_ssh_private_key_file: "{{ vault_ssh_key_path }}"
    ansible_network_os: fortinet.fortimanager.fortimanager
```

**Nota:** `ansible_user` y `ansible_ssh_private_key_file` usan valores del vault.
No pongas credenciales en texto plano en hosts.yml.

### Group Vars

```
ansible/inventory/production/group_vars/
├── all.yml                    # Variables globales (paths, timeouts, retencion)
├── fortigates.yml             # Variables comunes a todos los FortiGates
├── region_centro.yml          # Variables especificas de region centro
├── region_norte.yml           # Variables especificas de region norte
├── region_sur.yml             # Variables especificas de region sur
└── region_oriente.yml         # Variables especificas de region oriente
```

**Extracto de all.yml:**
```yaml
# Directorios
backup_base_dir: "/opt/backups/fortigates"
log_dir: "/var/log/fortigate-backup"
report_dir: "/opt/backups/reports"

# Timeouts (segundos)
ssh_timeout: 30
api_timeout: 60
ping_timeout: 5

# Backup schedule (ANSI cron)
backup_schedule_full: "0 2 * * *"
backup_schedule_incremental: "0 8,14,20 * * *"

# Retention
backup_retention_days: 90
s3_retention_days: 365

# Git
git_repo_path: "/opt/backups/fortigates/.git"
git_remote: "git@gitlab.internal.local:infrastructure/fortigate-backups.git"
git_branch: "main"

# Validacion
min_config_size_kb: 1
required_sections:
  - "config system global"
  - "config system interface"
  - "config router static"
  - "config firewall policy"
forbidden_patterns:
  - "set password"
  - "set private-key"
  - "set key"

# Notificaciones
notify_on_success: false
notify_on_warning: true
notify_on_failure: true
```

**Extracto de region_centro.yml:**
```yaml
region_name: "Centro"
region_code: "CEN"
timezone: "America/Santiago"
ntp_servers:
  - "0.pool.ntp.org"
  - "1.pool.ntp.org"
dns_servers:
  - "8.8.8.8"
  - "1.1.1.1"
```

### Makefile

El Makefile tiene 35+ targets. Los mas importantes:

```bash
make help              # Lista todos los targets con descripcion

make setup             # Instalacion completa (sudo)
make setup-dev         # Instalacion sin sudo

make backup            # Backup completo de todos los dispositivos
make backup-check      # Modo simulacion (dry-run)
make backup-centro     # Backup solo region centro
make backup-norte      # Backup solo region norte
make backup-sur        # Backup solo region sur
make backup-oriente    # Backup solo region oriente

make validate          # Validar todas las configuraciones
make verify            # Verificar hash chain (integridad)
make security          # Escanear secretos en todos los backups
make report            # Generar reporte HTML diario
make report-range      # Generar reporte por rango de fechas

make monitor           # Iniciar Docker Compose (Prometheus+Grafana)
make monitor-stop      # Detener monitoreo
make monitor-logs      # Ver logs de monitoreo
make health            # Health check completo del sistema
make compliance        # Verificar compliance (15 reglas)

make logs              # Ver logs en tiempo real (journald)
make status            # Estado del sistema (backups, disco, git)
make clean-backups     # Limpiar backups > 90 dias (retencion)
make clean-logs        # Limpiar logs > 30 dias

make test              # Ejecutar tests unitarios Python
make test-all          # Tests + validacion de sintaxis YAML

make dr-status         # Estado del sitio de DR
make dr-failover       # Ejecutar failover a DR
make dr-recover        # Recuperar desde DR al sitio principal
```

**Nota:** En Windows, usar `.\scripts\powershell\manage.ps1` en vez de `make`.

---

## Playbooks Detallados

### backup.yml

```bash
ansible-playbook ansible/playbooks/backup.yml
```

Orquestacion completa: backup -> validate -> git_sync -> notify

```yaml
# Extracto de backup.yml
- name: Backup FortiGate Configurations
  hosts: all
  serial: 10           # 10 dispositivos a la vez (evita sobrecarga)
  forks: 50            # 50 procesos paralelos
  max_fail_percentage: 30  # Si falla >30%, aborta todo
  gather_facts: false

  pre_tasks:
    - name: Verificar conectividad basica
      ansible.builtin.ping:
    - name: Verificar que podemos escalar a enable
      ansible.netcommon.cli_command:
        command: "show system status"

  roles:
    - role: backup_fortigate
      tags: [backup, always]
    - role: validate_config
      tags: [validate, always]
    - role: git_sync
      tags: [git, always]
    - role: notify
      tags: [notify, always]
      vars:
        notification_status: "{{ backup_success | default(false) }}"

  post_tasks:
    - name: Limpiar archivos temporales
      ansible.builtin.file:
        path: "{{ backup_temp_dir }}"
        state: absent
    - name: Registrar en metadata DB
      script: scripts/python/metadata_logger.py --register ...
```

**Variables de ejecucion:**
```bash
# Backup completo
ansible-playbook ansible/playbooks/backup.yml

# Solo una region
ansible-playbook ansible/playbooks/backup.yml --limit region_centro

# Solo un dispositivo
ansible-playbook ansible/playbooks/backup.yml --limit fgt-centro-dc01

# Simulacion (no hace cambios reales)
ansible-playbook ansible/playbooks/backup.yml --check

# Con output verboso (debug)
ansible-playbook ansible/playbooks/backup.yml -vvv

# Con tags especificos (solo backup, sin notify)
ansible-playbook ansible/playbooks/backup.yml --tags backup,validate

# Saltar validacion (urgencia)
ansible-playbook ansible/playbooks/backup.yml --skip-tags validate
```

### restore.yml

```bash
ansible-playbook ansible/playbooks/restore.yml \
    --limit fgt-centro-dc01 \
    -e "restore_version=20250101_020000"
```

```yaml
# Extracto de restore.yml
- name: Restore FortiGate Configuration
  hosts: "{{ target_host | default('all') }}"
  serial: 1            # UNO a la vez por seguridad
  max_fail_percentage: 0  # No tolera fallos

  vars_prompt:
    - name: confirm_restore
      prompt: "CONFIRMAR restauracion en {{ target_host }}? (yes/no)"
      default: "no"
      private: false

  pre_tasks:
    - name: Verificar que el archivo de backup existe
      ansible.builtin.stat:
        path: "/opt/backups/fortigates/{{ inventory_hostname }}/{{ restore_version[:8] }}/{{ inventory_hostname | upper }}_{{ restore_version }}_full_config.conf"
      register: backup_file
      fail:
        msg: "Backup no encontrado: {{ restore_version }}"
      when: not backup_file.stat.exists

    - name: Backup pre-restauracion (snapshot)
      include_role:
        name: backup_fortigate
      vars:
        backup_type: pre_restore

    - name: Validar que el dispositivo es reachable
      ansible.builtin.ping:

  roles:
    - role: restore_fortigate
      vars:
        restore_type: "{{ restore_type | default('full') }}"  # full o merge

  post_tasks:
    - name: Verificar estado post-restore
      ansible.netcommon.cli_command:
        command: "show system status"
      register: post_status

    - name: Validar config post-restore
      include_role:
        name: validate_config

    - name: Notificar restauracion completada
      include_role:
        name: notify
      vars:
        notification_type: restore
```

**Modos de restauracion:**
```bash
# Restore completo (reemplaza toda la config)
ansible-playbook ansible/playbooks/restore.yml --limit fgt-centro-dc01 \
    -e "restore_version=20250101_020000" -e "restore_type=full"

# Merge (solo agrega/cambia secciones, no borra nada)
ansible-playbook ansible/playbooks/restore.yml --limit fgt-centro-dc01 \
    -e "restore_version=20250101_020000" -e "restore_type=merge"
```

**APROBACION REQUERIDA para dispositivos primary/secondary:**
El playbook pide confirmacion manual antes de restaurar en dispositivos con rol=primary o secondary. Los edge no requieren aprobacion.

### validate_all.yml

```bash
# Validar backups existentes de una fecha especifica
ansible-playbook ansible/playbooks/validate_all.yml \
    -e "validate_date=2025-01-15"

# Validar con enforcement (falla si no pasa)
ansible-playbook ansible/playbooks/validate_all.yml \
    -e "validate_date=2025-01-15" -e "enforce_compliance=true"
```

### emergency_rollback.yml

```bash
# Rollback rapido para equipos edge (sin aprobacion)
ansible-playbook ansible/playbooks/emergency_rollback.yml \
    --limit fgt-centro-suc01 \
    -e "restore_version=20250101_020000"
```

**Diferencias con restore.yml:**
- No pide confirmacion para equipos edge
- Logging mas detallado (SIEM)
- Backup snapshot automatico pre-rollback
- Envia alerta PagerDuty inmediata

---

## Roles Ansible

### backup_fortigate

Path: `ansible/roles/backup_fortigate/`

Selecciona automaticamente el metodo segun `backup_method` del inventario.

**Tareas principales:**
- `tasks/via_ssh.yml`: Usa `ansible.netcommon.cli_command` para ejecutar comandos via SSH
- `tasks/via_api.yml`: Usa `ansible.builtin.uri` para llamar REST API de FortiGate
- `tasks/main.yml`: Decide que metodo usar, orquesta metadata y validacion basica
- `handlers/main.yml`: Cleanup (comprime backups viejos, elimina temporales)
- `vars/main.yml`: Matriz de compatibilidad modelo-firmware-metodo

**Output por dispositivo:**
```
/opt/backups/fortigates/{hostname}/{YYYY-MM-DD}/
  {HOSTNAME}_{YYYYMMDD}_{HHMMSS}_full_config.conf
  {HOSTNAME}_{YYYYMMDD}_{HHMMSS}_system_status.json
  {HOSTNAME}_{YYYYMMDD}_{HHMMSS}_ha_status.json    (si aplica)
  {HOSTNAME}_{YYYYMMDD}_{HHMMSS}_metadata.json
  validation_report.json
```

**Metadata.json:**
```json
{
  "hostname": "fgt-centro-dc01",
  "serial": "FG100F12345678",
  "firmware": "v7.4.1",
  "uptime": "45 days 3 hours 12 minutes",
  "backup_method": "api",
  "backup_timestamp": "2025-01-15T02:00:15-03:00",
  "config_size_bytes": 28473,
  "sha256_hash": "a1b2c3d4e5f6...",
  "previous_hash": "9f8e7d6c5b4a...",
  "validation_status": "passed",
  "validation_checks": 15,
  "validation_failures": 0
}
```

### validate_config

Path: `ansible/roles/validate_config/`

Copia `files/validate_config.py` al servidor, lo ejecuta contra cada backup,
parsea el JSON de salida y falla si hay issues bloqueantes.

**15 checks de validacion:**
1. `file_exists`: El archivo existe
2. `min_size`: Tamanio minimo (> 1 KB)
3. `max_size`: Tamanio maximo (< 10 MB, evita archivos corruptos)
4. `brace_balance`: Llaves {} balanceadas (sintaxis)
5. `required_sections`: Secciones obligatorias presentes
6. `no_forbidden_patterns`: Sin patrones prohibidos
7. `no_empty_sections`: Sin secciones vacias
8. `vdom_syntax`: Sintaxis de VDOM valida (si aplica)
9. `ip_addresses_valid`: Direcciones IP en formato valido
10. `no_duplicate_entries`: Sin entradas duplicadas
11. `security_policy_check`: Politicas de seguridad minimas
12. `admin_access_check`: Acceso administrativo configurado
13. `logging_enabled`: Logging configurado
14. `ntp_configured`: NTP configurado
15. `dns_configured`: DNS configurado

### git_sync

Path: `ansible/roles/git_sync/`

Inicializa repo Git si no existe, hace add/commit/push con tagging.
Usa git-crypt para cifrado del repo (si esta configurado).

**Estructura de commits:**
```
backup-20250115-020000
  ├── fgt-centro-dc01/2025-01-15/FGT-CENTRO-DC01_20250115_020000_full_config.conf
  ├── fgt-norte-dc01/2025-01-15/FGT-NORTE-DC01_20250115_020000_full_config.conf
  ├── manifest_2025-01-15.json
  └── .hash_chain.json
```

**Tags:**
```
backup-20250115-020000  (cada ejecucion)
backup-20250115         (ultimo backup del dia)
backup-weekly-03        (backup semanal, semana 3)
```

### restore_fortigate

Path: `ansible/roles/restore_fortigate/`

Localiza backup por version, lo transfiere via SCP al FortiGate,
ejecuta `execute restore config full` o `execute restore config merge` via CLI.

**Flujo:**
1. Busca archivo en `/opt/backups/fortigates/{hostname}/{fecha}/`
2. Verifica hash contra `.hash_chain.json`
3. Transfiere config via SCP a `{fortigate_ip}:{temp_path}`
4. Ejecuta restore CLI
5. Verifica estado post-restore
6. Registra en audit log

### notify

Path: `ansible/roles/notify/`

Multiples canales de notificacion:

```yaml
# Slack (via webhook)
- name: Notify Slack
  ansible.builtin.uri:
    url: "{{ vault_slack_webhook_url }}"
    method: POST
    body_format: json
    body:
      text: "{{ notification_message }}"
      attachments: "{{ notification_attachments | default(omit) }}"

# Email (via mail module)
- name: Notify Email
  ansible.builtin.mail:
    to: "{{ vault_notification_email }}"
    subject: "[Backup] {{ notification_subject }}"
    body: "{{ notification_body }}"

# PagerDuty (via API)
- name: Notify PagerDuty
  ansible.builtin.uri:
    url: "https://events.pagerduty.com/v2/enqueue"
    method: POST
    body_format: json
    body:
      routing_key: "{{ vault_pagerduty_integration_key }}"
      event_action: "trigger"
      payload:
        summary: "{{ notification_summary }}"
        severity: "{{ notification_severity }}"
        source: "fortigate-backup-{{ inventory_hostname }}"

# Syslog (local)
- name: Notify Syslog
  community.general.syslogger:
    msg: "{{ notification_message }}"
    priority: "{{ syslog_priority }}"
```

---

## Scripts Python

### config_validator.py

Path: `scripts/python/config_validator.py`

```bash
python scripts/python/config_validator.py \
    --config /opt/backups/fortigates/fgt-centro-dc01/2025-01-15/config.conf \
    --output /opt/backups/fortigates/fgt-centro-dc01/2025-01-15/validation_report.json \
    --required-sections "config system global,config system interface,config router static,config firewall policy" \
    --forbidden-patterns "set password,set private-key"
```

**Output JSON:**
```json
{
  "file": "/opt/backups/fortigates/fgt-centro-dc01/2025-01-15/config.conf",
  "timestamp": "2025-01-15T02:15:30",
  "overall_status": "PASS",
  "checks": [
    {"name": "file_exists", "status": "PASS", "detail": "File exists (28473 bytes)"},
    {"name": "min_size", "status": "PASS", "detail": "28473 bytes > 1024 bytes"},
    {"name": "brace_balance", "status": "PASS", "detail": "142 opening, 142 closing"},
    {"name": "required_sections", "status": "PASS", "detail": "All 4 required sections present"},
    {"name": "security_policy_check", "status": "WARN", "detail": "Policy 'internet-access' has no logging"},
    {"name": "forbidden_patterns", "status": "PASS", "detail": "No forbidden patterns found"}
  ],
  "summary": {
    "total": 15,
    "passed": 14,
    "warnings": 1,
    "failures": 0
  }
}
```

### secrets_scanner.py

Path: `scripts/python/secrets_scanner.py`

```bash
# Escanear un archivo
python scripts/python/secrets_scanner.py \
    --path /opt/backups/fortigates/fgt-centro-dc01/2025-01-15/config.conf \
    --output sarif \
    --entropy-threshold 4.5

# Escanear todo el directorio de backups
python scripts/python/secrets_scanner.py \
    --path /opt/backups/fortigates/ \
    --recursive \
    --output sarif \
    --git-diff

# Modo git-diff (solo cambios no commiteados)
python scripts/python/secrets_scanner.py \
    --path /opt/backups/fortigates/ \
    --git-diff
```

**Patrones detectados (20+):**
- FortiGate API keys (`FG API` tokens)
- SSH private keys (`-----BEGIN OPENSSH PRIVATE KEY-----`)
- Passwords en config (`set password`, `set passwd`, `set psksecret`)
- Certificados TLS inline (`-----BEGIN CERTIFICATE-----`)
- VPN preshared keys
- LDAP bind credentials
- RADIUS shared secrets
- SNMP community strings (public/private literal)
- Generic: AWS keys, GitHub tokens, Slack tokens, JWT, Base64 high-entropy

**Analisis de entropia:**
Usa Shannon entropy. Cadenas con entropia > 4.5 y longitud > 20 chars
se marcan como "probable secreto" aunque no matcheen un patron conocido.

### hash_verifier.py

Path: `scripts/python/hash_verifier.py`

```bash
# Calcular hash de un backup
python scripts/python/hash_verifier.py \
    --backup-dir /opt/backups/fortigates/ \
    --config-file fgt-centro-dc01/2025-01-15/FGT-CENTRO-DC01_20250115_020000_full_config.conf

# Construir cadena de hash (Merkle DAG)
python scripts/python/hash_verifier.py \
    --backup-dir /opt/backups/fortigates/ \
    --build-chain

# Verificar cadena completa (detecta manipulacion)
python scripts/python/hash_verifier.py \
    --backup-dir /opt/backups/fortigates/ \
    --verify-chain

# Verificar dispositivo especifico
python scripts/python/hash_verifier.py \
    --backup-dir /opt/backups/fortigates/ \
    --verify-chain \
    --hostname fgt-centro-dc01
```

**Output de verificacion:**
```
=== Hash Chain Verification Report ===
Chain file: /opt/backups/fortigates/.hash_chain.json
Total entries: 128

Host: fgt-centro-dc01 (32 entries)
  ✓ 2025-01-01 02:00: hash=a1b2... -> chain OK
  ✓ 2025-01-01 08:00: hash=c3d4... -> chain OK
  ✓ 2025-01-01 14:00: hash=e5f6... -> chain OK
  ...
  ✓ 2025-01-15 02:00: hash=x9y0... -> chain OK

Host: fgt-norte-dc01 (32 entries) -> all OK
Host: fgt-sur-dc01 (32 entries) -> all OK
Host: fgt-oriente-dc01 (32 entries) -> all OK

Status: ALL PASS (128/128 entries verified)
No tampering detected.
```

**Si detecta manipulacion:**
```
  ✗ 2025-01-10 02:00: hash=abcdef... -> CHAIN BREAK!
    Expected previous hash: 123456...
    Actual previous hash:  789abc...
    File may have been modified: /opt/backups/fortigates/fgt-centro-dc01/2025-01-10/config.conf
```

### metadata_logger.py

Path: `scripts/python/metadata_logger.py`

```bash
# Registrar un backup
python scripts/python/metadata_logger.py \
    --register \
    --hostname fgt-centro-dc01 \
    --status success \
    --size 28473 \
    --hash a1b2c3d4e5f6... \
    --method api

# Query: ultimos backups
python scripts/python/metadata_logger.py \
    --query \
    --limit 20

# Query: backups fallidos
python scripts/python/metadata_logger.py \
    --query \
    --status failed

# Estadisticas
python scripts/python/metadata_logger.py \
    --stats

# Reporte de compliance
python scripts/python/metadata_logger.py \
    --compliance-report
```

**Esquema SQLite:**
```sql
CREATE TABLE device_backups (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hostname TEXT NOT NULL,
    backup_date TEXT NOT NULL,
    backup_time TEXT NOT NULL,
    config_size INTEGER,
    sha256_hash TEXT,
    backup_method TEXT,
    status TEXT CHECK(status IN ('success','failed','warning')),
    firmware_version TEXT,
    serial_number TEXT,
    region TEXT,
    validation_status TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(hostname, backup_date, backup_time)
);

CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action TEXT NOT NULL,
    hostname TEXT,
    user TEXT,
    details TEXT,
    status TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE compliance_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    check_date TEXT NOT NULL,
    hostname TEXT NOT NULL,
    check_name TEXT NOT NULL,
    status TEXT CHECK(status IN ('pass','warn','fail')),
    detail TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE backup_summary (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    summary_date TEXT UNIQUE NOT NULL,
    total_devices INTEGER,
    successful_backups INTEGER,
    failed_backups INTEGER,
    total_size_bytes INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### report_generator.py

Path: `scripts/python/report_generator.py`

```bash
# Reporte diario
python scripts/python/report_generator.py \
    --date 2025-01-15 \
    --output-dir /opt/backups/reports/ \
    --format html

# Reporte por rango
python scripts/python/report_generator.py \
    --start-date 2025-01-01 \
    --end-date 2025-01-15 \
    --output-dir /opt/backups/reports/ \
    --format html

# Reporte JSON (para consumir desde API)
python scripts/python/report_generator.py \
    --date 2025-01-15 \
    --output-dir /opt/backups/reports/ \
    --format json
```

**El reporte HTML incluye:**
- Tabla de dispositivos con estado (success/warning/fail)
- Resumen: total, exitosos, fallidos, warnings
- Tamanio total de backups
- Badges de validacion (PASS/WARN/FAIL por check)
- Grafico de tendencia (ultimos 30 dias)
- Enlaces a archivos de config

### health_check.py

Path: `scripts/python/health_check.py`

```bash
# Health check completo
python scripts/python/health_check.py \
    --inventory ansible/inventory/production/hosts.yml \
    --config ansible/ansible.cfg

# Solo un dispositivo
python scripts/python/health_check.py \
    --host fgt-centro-dc01

# Output Prometheus (para ser scrapeado)
python scripts/python/health_check.py \
    --prometheus-output /var/lib/prometheus/node-exporter/fortigate-backup.prom
```

**Checks:**
- TCP connectivity (puerto 22 o 443 segun metodo)
- DNS resolution
- TLS certificate validity (para API)
- Response time (latencia)
- Backup directory exists and writable
- Git repo exists and is accessible
- Disk space for backups
- Hash chain integrity

### inventory_generator.py

Path: `scripts/python/inventory_generator.py`

```bash
# Generar inventory desde CSV
python scripts/python/inventory_generator.py \
    --csv dispositivos.csv \
    --output ansible/inventory/production/hosts.yml

# Formato CSV esperado:
# hostname,ansible_host,region,role,model,serial,firmware,method,location
# fgt-centro-dc01,10.1.1.1,centro,primary,FG-100F,FG100F12345678,v7.4.1,api,Santiago-DC01

# Validar inventory existente
python scripts/python/inventory_generator.py \
    --validate ansible/inventory/production/hosts.yml
```

---

## Scripts Bash

### bootstrap.sh

Path: `scripts/bash/bootstrap.sh`

```bash
sudo ./scripts/bash/bootstrap.sh
```

**Fases:**
1. `install_packages`: Python, Ansible, Git, OpenSSH, make, curl, rsync, docker
2. `create_directories`: /opt/backups/fortigates, /var/log/fortigate-backup, /opt/backups/reports
3. `setup_python_venv`: python3 -m venv venv, pip install -r requirements.txt
4. `install_ansible_collections`: ansible-galaxy collection install -r ansible/requirements.yml
5. `generate_ssh_keys`: ssh-keygen -t ed25519 -f ~/.ssh/fortigate-backup-key
6. `setup_git`: git init en /opt/backups/fortigates, git config user/email
7. `configure_firewall`: ufw allow from {management_networks} to any port 22,9090,3000
8. `setup_logrotate`: Configuracion de rotacion de logs (30 dias)
9. `setup_systemd_service`: Servicio fortigate-backup.timer + fortigate-backup.service
10. `copy_vault_password`: Copia .vault_password_template -> .vault_password

**Detecta WSL2** y ajusta paths automaticamente.

### setup_git_crypt.sh

Path: `scripts/bash/setup_git_crypt.sh`

```bash
# Inicializar git-crypt en el repo de backups
./scripts/bash/setup_git_crypt.sh --init

# Agregar usuario GPG
./scripts/bash/setup_git_crypt.sh --add-user "admin@internal.local"

# Bloquear/desbloquear
./scripts/bash/setup_git_crypt.sh --lock
./scripts/bash/setup_git_crypt.sh --unlock

# Estado
./scripts/bash/setup_git_crypt.sh --status

# Exportar/importar clave simetrica
./scripts/bash/setup_git_crypt.sh --export-key backup-crypt.key
./scripts/bash/setup_git_crypt.sh --import-key backup-crypt.key
```

**Requisito:** Tener `git-crypt` instalado. No es obligatorio - el sistema funciona sin el.

### rotate_credentials.sh

Path: `scripts/bash/rotate_credentials.sh`

```bash
# Rotar claves SSH (cada 90 dias)
sudo ./scripts/bash/rotate_credentials.sh --rotate-ssh

# Rotar tokens API (cada 30 dias)
sudo ./scripts/bash/rotate_credentials.sh --rotate-api

# Rotar ambos
sudo ./scripts/bash/rotate_credentials.sh --rotate-all

# Verificar conectividad post-rotacion
sudo ./scripts/bash/rotate_credentials.sh --verify

# Rollback si algo falla
sudo ./scripts/bash/rotate_credentials.sh --rollback
```

**Flujo de rotacion SSH:**
1. Genera nueva clave ed25519
2. Conecta a cada FortiGate con clave VIEJA
3. Agrega clave NUEVA al usuario backup-admin
4. Prueba conexion con clave NUEVA
5. Si ok: elimina clave VIEJA del FortiGate y del servidor
6. Si falla: restaura clave VIEJA (rollback)
7. Registra en audit log

### dr_failover.sh

Path: `scripts/bash/dr_failover.sh`

```bash
# Ver estado de DR
./scripts/bash/dr_failover.sh --status

# Verificar integridad de backups en DR
./scripts/bash/dr_failover.sh --verify

# Replicar backups al sitio DR (rsync + git push)
./scripts/bash/dr_failover.sh --replicate

# Failover: activar sitio DR como primario
./scripts/bash/dr_failover.sh --failover-to dr-site.internal.local

# Recovery: volver al sitio primario
./scripts/bash/dr_failover.sh --recover
```

**Ver `docs/DISASTER_RECOVERY.md` para procedimiento detallado.**

---

## Scripts PowerShell

### bootstrap-wsl.ps1

Path: `scripts/powershell/bootstrap-wsl.ps1`

```powershell
# Instalacion completa de WSL2 + Ubuntu + sistema de backups
.\scripts\powershell\bootstrap-wsl.ps1
```

**Parametros:**
```powershell
# Especificar distribucion
.\scripts\powershell\bootstrap-wsl.ps1 -Distro Ubuntu-24.04

# Saltar instalacion de WSL2 (si ya esta instalado)
.\scripts\powershell\bootstrap-wsl.ps1 -SkipWSL

# Solo validar (no instalar)
.\scripts\powershell\bootstrap-wsl.ps1 -ValidateOnly
```

**Que hace:**
1. Verifica Windows version >= 19041
2. Verifica virtualizacion habilitada
3. Activa WSL (dism.exe /online /enable-feature)
4. Instala VirtualMachinePlatform
5. wsl --set-default-version 2
6. wsl --install -d Ubuntu-24.04 (o distribucion especificada)
7. Crea usuario backup-admin
8. Monta proyecto en /opt/fortigate-backup
9. Ejecuta bootstrap.sh dentro de WSL2
10. Valida instalacion

### run-ansible.ps1

Path: `scripts/powershell/run-ansible.ps1`

```powershell
# Ejecutar playbook
.\scripts\powershell\run-ansible.ps1 -Playbook backup.yml

# Con limit
.\scripts\powershell\run-ansible.ps1 -Playbook backup.yml -Limit fgt-centro-dc01

# Modo check
.\scripts\powershell\run-ansible.ps1 -Playbook backup.yml -Check

# Con tags
.\scripts\powershell\run-ansible.ps1 -Playbook backup.yml -Tags backup,validate

# Con variables extra
.\scripts\powershell\run-ansible.ps1 -Playbook backup.yml -ExtraVars @{restore_version="20250101_020000"}
```

**Como funciona:** Convierte paths Windows -> WSL2, monta el proyecto si no lo esta,
activa venv, ejecuta ansible-playbook con los parametros, y retorna el codigo de salida.

### manage.ps1

Path: `scripts/powershell/manage.ps1`

```powershell
# Todos los comandos
.\scripts\powershell\manage.ps1 help

# Commands:
#   status              Estado del sistema
#   backup              Backup completo
#   backup -Check       Backup simulado
#   backup -Region centro  Backup por region
#   validate            Validar configs
#   report              Reporte HTML
#   report -Start 2025-01-01 -End 2025-01-15  Reporte por rango
#   monitor             Iniciar monitoreo (Docker Compose)
#   monitor -Stop       Detener monitoreo
#   logs                Ver logs
#   shell               Entrar a WSL2
#   health              Health check
#   security            Escanear secretos
#   wsl-setup           Reinstalar WSL2
#   dr-status           Estado de DR
#   dr-failover         Ejecutar failover
#   compliance          Compliance check
#   verify              Verificar hash chain
#   clean-backups       Limpiar backups antiguos
```

**Ejemplos:**
```powershell
# Estado rapido
.\scripts\powershell\manage.ps1 status

# Backup de emergencia
.\scripts\powershell\manage.ps1 backup

# Backup solo region norte (mas rapido)
.\scripts\powershell\manage.ps1 backup -Region norte

# Validar sin ejecutar backup
.\scripts\powershell\manage.ps1 validate

# Ver log de ultima ejecucion
.\scripts\powershell\manage.ps1 logs

# Health check completo
.\scripts\powershell\manage.ps1 health
```

---

## Monitoreo

### Stack (Docker Compose)

```bash
make monitor
# Inicia: Prometheus, Grafana, Alertmanager, Node Exporter, Pushgateway
# Puertos:
#   Grafana:      localhost:3000
#   Prometheus:   localhost:9090
#   Alertmanager: localhost:9093
#   Node Exporter: localhost:9100
```

### Prometheus Metrics

El exporter `monitoring/ansible_exporter.py` expone:

```
# HELP fortigate_backup_success_total Backups exitosos por dispositivo
# TYPE fortigate_backup_success_total counter
fortigate_backup_success_total{hostname="fgt-centro-dc01",region="centro"} 42

# HELP fortigate_backup_failure_total Backups fallidos por dispositivo
# TYPE fortigate_backup_failure_total counter
fortigate_backup_failure_total{hostname="fgt-centro-dc01",region="centro"} 1

# HELP fortigate_backup_duration_seconds Duracion del backup
# TYPE fortigate_backup_duration_seconds gauge
fortigate_backup_duration_seconds{hostname="fgt-centro-dc01"} 45.2

# HELP fortigate_backup_config_size_bytes Tamanio de config en bytes
# TYPE fortigate_backup_config_size_bytes gauge
fortigate_backup_config_size_bytes{hostname="fgt-centro-dc01"} 28473

# HELP fortigate_backup_last_timestamp Timestamp del ultimo backup
# TYPE fortigate_backup_last_timestamp gauge
fortigate_backup_last_timestamp{hostname="fgt-centro-dc01"} 1.736914e+09

# HELP fortigate_backup_validation_status Estado de validacion (0=pass,1=warn,2=fail)
# TYPE fortigate_backup_validation_status gauge
fortigate_backup_validation_status{hostname="fgt-centro-dc01"} 0

# HELP fortigate_backup_git_commits_total Total de commits Git por dispositivo
# TYPE fortigate_backup_git_commits_total counter
fortigate_backup_git_commits_total{hostname="fgt-centro-dc01"} 128

# HELP fortigate_disk_usage_bytes Uso de disco del directorio de backups
# TYPE fortigate_disk_usage_bytes gauge
fortigate_disk_usage_bytes{hostname="fgt-centro-dc01"} 25165824
```

### Alertas (15 reglas en Prometheus)

| Alerta | Condicion | Severidad | Channel |
|--------|-----------|-----------|---------|
| BackupJobFailed | `rate(fortigate_backup_failure_total[1h]) > 0` | critical | PagerDuty + Slack |
| DeviceUnreachable | `time() - fortigate_backup_last_timestamp > 21600` | critical | PagerDuty |
| DiskSpaceLow | `node_filesystem_avail_bytes{mount="/opt"} < 0.2` | critical | PagerDuty |
| BackupStalled | `time() - fortigate_backup_last_timestamp > 43200` | warning | Slack |
| HighLatency | `fortigate_backup_duration_seconds > 300` | warning | Slack |
| ValidationWarning | `fortigate_backup_validation_status == 1` | warning | Slack |
| ValidationFailed | `fortigate_backup_validation_status == 2` | critical | PagerDuty + Slack |
| SecretsFound | `fortigate_secrets_found_total > 0` | critical | PagerDuty + Slack |
| ConfigSizeAnomaly | `abs(fortigate_backup_config_size_bytes - avg_over_time[7d]) > 0.5` | warning | Slack |
| GitPushFailed | `fortigate_git_push_failures_total > 0` | critical | PagerDuty |
| HashChainBroken | `fortigate_hash_chain_status == 0` | critical | PagerDuty |
| ComplianceLow | `fortigate_compliance_score < 0.8` | warning | Slack |
| CertificateExpiring | `fortigate_tls_cert_days_remaining < 30` | warning | Slack |
| BackupCountLow | `fortigate_backup_success_total < expected` | warning | Slack |
| DRReplicationStale | `time() - fortigate_dr_last_replication > 86400` | critical | PagerDuty |

### Grafana Dashboard

6 paneles preconfigurados en `monitoring/grafana/dashboards/fortigate-backup-dashboard.json`:

1. **Backup Success Rate** (stat): % de backups exitosos en 24h
2. **Active Devices** (stat): Cuantos dispositivos se respaldaron hoy
3. **Disk Usage** (gauge): % de disco usado en /opt
4. **Total Backup Size** (stat): Tamanio total de todos los backups
5. **Backups Over Time** (time series): Grafico de lin eas: exitos vs fallos por dia
6. **Device Status Table** (table): Tabla con ultimo estado de cada dispositivo

---

## Seguridad

### Capas de seguridad

```
CAPA 1 - RED:
  Bastion host como unico punto de entrada
  Firewall ufw: solo puertos 22, 9090, 3000 desde redes de gestion
  SSH key-based auth (no passwords)
  Host key validation estricta (StrictHostKeyChecking=yes)

CAPA 2 - AUTENTICACION:
  Usuario dedicado backup-admin en FortiGates (rol read-only)
  Claves SSH ed25519 (rotacion cada 90 dias)
  API tokens con privilegios minimos (solo backup config)

CAPA 3 - ALMACENAMIENTO:
  Ansible Vault (AES-256) para credenciales
  git-crypt (AES-256-GCM) para repo Git cifrado
  Hash chain (SHA-256 Merkle DAG) para deteccion de manipulacion
  S3 Object Lock (WORM) - backups inmutables 365 dias

CAPA 4 - CODIGO:
  Secrets scanner en cada backup (20+ patrones + entropia)
  Pre-commit hooks (detecta secretos antes de commit)
  Validacion de config con 15 checks
  GPG signing de commits

CAPA 5 - OPERACIONES:
  Audit logging en SQLite
  Notificaciones multi-canal
  Rotacion periodica de credenciales
  Aprobacion requerida para restore en dispositivos criticos
```

### Threat Model

| Amenaza | Mitigacion |
|---------|-----------|
| Acceso no autorizado al servidor | SSH key + firewall + bastion |
| Intercepcion de backups en transito | SSH/HTTPS obligatorio |
| Modificacion de backups almacenados | Hash chain + git-crypt + inmutabilidad S3 |
| Robo de credenciales | Ansible Vault + rotacion + minimo privilegio |
| Ataque man-in-the-middle | Host key validation + TLS 1.3 |
| Perdida de datos por desastre | DR site + replicacion + S3 |
| Acceso interno malicioso | RBAC + audit log + compliance checks |

---

## CI/CD

### GitLab CI (`.gitlab-ci.yml`)

8 stages, 12 jobs:

| Stage | Job | Descripcion |
|-------|-----|-------------|
| validate | lint-yaml | Valida sintaxis YAML (ansible-lint) |
| validate | lint-python | Valida sintaxis Python (flake8, pylint) |
| validate | check-format | Verifica formato con black |
| security | scan-secrets | Escanea el repo con git-secrets |
| security | scan-vulnerabilities | Escanea dependencias (pip-audit) |
| test | unit-test | Ejecuta pytest (tests/test_scripts/) |
| test | ansible-syntax | Verifica sintaxis de todos los playbooks |
| backup | dry-run | Ejecuta backup en modo check contra staging |
| backup | full-backup | Backup real (solo en schedule o manual) |
| verify | validate-backup | Valida los backups generados |
| report | generate-report | Genera reporte HTML |
| deploy | deploy-monitoring | Despliega config de Prometheus/Grafana |

**Triggers:**
- Push a main: validate + security + test
- Schedule (diario 02:00): backup completo
- Manual: cualquier stage individual
- Merge request: validate + security + test (sin backup)

### GitHub Actions (`.github/workflows/backup-pipeline.yml`)

Equivalente funcional a GitLab CI. Mismos stages y jobs.
Usa `workflow_dispatch` para ejecucion manual con parametros:

```yaml
on:
  schedule:
    - cron: '0 2 * * *'    # Backup completo 02:00
    - cron: '0 8 * * *'    # Incremental 08:00
    - cron: '0 14 * * *'   # Incremental 14:00
    - cron: '0 20 * * *'   # Incremental 20:00
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:
    inputs:
      playbook:
        description: 'Playbook a ejecutar'
        default: 'backup.yml'
      limit:
        description: 'Limitar a host o grupo'
        required: false
      check_mode:
        description: 'Modo simulación'
        type: boolean
        default: false
```

---

## DR Failover

### Estrategia

- **RPO (Recovery Point Objective):** 6 horas (perdida maxima de datos)
- **RTO (Recovery Time Objective):** 1 hora (tiempo de recuperacion)
- **Sitio DR:** Servidor en nube o datacenter secundario
- **Replicacion:** rsync + git push cada 6 horas post-backup

### Procedimiento

```bash
# 1. Verificar estado
./scripts/bash/dr_failover.sh --status

# 2. Verificar integridad en DR
./scripts/bash/dr_failover.sh --verify

# 3. Replicar manualmente (si la automatica fallo)
./scripts/bash/dr_failover.sh --replicate

# 4. Failover a DR
./scripts/bash/dr_failover.sh --failover-to dr-site.internal.local

# 5. En DR site, verificar que todo funciona
python3 scripts/python/health_check.py --all
make status

# 6. Cuando el sitio primario vuelva:
./scripts/bash/dr_failover.sh --recover
```

**Ver `docs/DISASTER_RECOVERY.md` para procedimiento detallado con checklists.**

---

## Testing

```bash
# Tests unitarios Python
make test
# Equivalent to: cd tests && python -m pytest test_scripts/ -v

# Tests + validacion YAML
make test-all

# Tests especificos
cd tests
python -m pytest test_scripts/test_validators.py -v -k "test_valid_config"
python -m pytest test_scripts/test_validators.py -v -k "test_security"

# Ansible syntax check
ansible-playbook ansible/playbooks/backup.yml --syntax-check
ansible-playbook ansible/playbooks/restore.yml --syntax-check

# Verificar conectividad (sin hacer backup)
ansible all -i ansible/inventory/production/hosts.yml -m ping -o
```

**Tests incluidos:**
- `test_validators.py`: 12+ tests unitarios
  - `test_valid_config`: Configuracion valida pasa todos los checks
  - `test_missing_sections`: Config sin secciones requeridas falla
  - `test_forbidden_patterns`: Config con passwords en texto plano falla
  - `test_unbalanced_braces`: Config con llaves desbalanceadas falla
  - `test_min_size_failure`: Archivo vacio falla
  - `test_max_size_failure`: Archivo muy grande falla
  - `test_security_policy_check`: Politicas sin logging generan warning
  - `test_hash_verifier_hash`: Calculo de hash correcto
  - `test_hash_verifier_verify`: Verificacion de hash correcta
  - `test_hash_chain_build`: Construccion de cadena correcta
  - `test_hash_chain_verify`: Verificacion de cadena completa
  - `test_hash_tamper_detection`: Deteccion de manipulacion

---

## Uso Diario

### Linux

```bash
# MAÑANA - Verificar backups nocturnos
make status           # Estado general
make logs             # Ultimos logs
ls -la /opt/backups/fortigates/*/$(date +%Y-%m-%d)/  # Backups de hoy

# SEMANAL - Generar reportes
make report           # Reporte HTML
make validate         # Validar configs

# MENSUAL - Mantenimiento
make verify           # Hash chain integrity
make security         # Secrets scan
make compliance       # Compliance check
make clean-backups    # Limpiar > 90 dias

# TRIMESTRAL - Rotacion
sudo ./scripts/bash/rotate_credentials.sh --rotate-ssh
sudo ./scripts/bash/rotate_credentials.sh --rotate-api

# EMERGENCIAS
make backup           # Backup inmediato
make monitor          # Abrir dashboards
ansible-playbook ansible/playbooks/restore.yml --limit fgt-centro-dc01 -e "restore_version=20250101_020000"
```

### Windows (PowerShell)

```powershell
# DIARIO
.\scripts\powershell\manage.ps1 status
.\scripts\powershell\manage.ps1 logs

# SEMANAL
.\scripts\powershell\manage.ps1 report
.\scripts\powershell\manage.ps1 validate

# MENSUAL
.\scripts\powershell\manage.ps1 verify
.\scripts\powershell\manage.ps1 security
.\scripts\powershell\manage.ps1 compliance

# EMERGENCIAS
.\scripts\powershell\manage.ps1 backup
.\scripts\powershell\manage.ps1 shell
# Dentro de WSL2:
ansible-playbook ansible/playbooks/restore.yml --limit fgt-centro-dc01 -e "restore_version=20250101_020000"
```

---

## Preguntas Frecuentes

### Instalacion y Configuracion

**P: `make setup` pide sudo. Que pasa si no tengo sudo?**
R: Usar `make setup-dev`. No configurara systemd, firewall, ni creara el usuario.
Funciona para desarrollo y pruebas.

**P: El bootstrap-wsl.ps1 falla con "No se pudo instalar WSL2".**
R: Activar manualmente:
```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all
wsl --set-default-version 2
wsl --install -d Ubuntu-24.04
```
Reiniciar y ejecutar de nuevo.

**P: WSL2 consume mucha RAM. Como limitarla?**
R: Crear `%USERPROFILE%\.wslconfig`:
```ini
[wsl2]
memory=4GB
processors=2
swap=2GB
```
Luego `wsl --shutdown` y volver a abrir.

**P: Necesito instalar git-crypt?**
R: No, es opcional. Sin el, el repo Git no esta cifrado pero el sistema funciona igual.
Evaluar si se necesita cifrado del repo segun politicas de seguridad.

**P: Como cambio el password del vault?**
R: `ansible-vault rekey ansible/vault/vault.yml`. Luego actualizar `ansible/vault/.vault_password`.

### Operacion

**P: Que pasa si un FortiGate no esta reachable durante el backup?**
R: El playbook continua con los demas (max_fail_percentage=30). El dispositivo fallido se registra como "unreachable" en metadata, se envia alerta Slack, y se reintenta en el proximo ciclo (6h).

**P: Como se si un backup se completo correctamente?**
R: `make status` muestra resumen. `make report` genera HTML detallado.
Tambien revisar `make logs` para ver la salida de Ansible.

**P: Los backups ocupan mucho disco cuando limpiarlos?**
R: `make clean-backups` elimina backups > 90 dias (retencion configurable en `group_vars/all.yml`).
O manualmente: `find /opt/backups/fortigates/* -maxdepth 1 -type d -mtime +90 -exec rm -rf {} +`

**P: Que pasa si se llena el disco?**
R: Alerta DiskSpaceLow via PagerDuty cuando <20% libre. El playbook falla con "no space left".
Solucion: limpiar backups viejos o ampliar disco.

**P: Como hago backup manual de emergencia?**
R: `make backup` o `ansible-playbook ansible/playbooks/backup.yml`. Si solo un dispositivo: `--limit fgt-centro-dc01`.

### Restauracion

**P: Como restauro un backup en un FortiGate?**
R:
```bash
# 1. Listar versiones disponibles
git -C /opt/backups/fortigates tag -l 'backup-*' | sort -r | head -10

# 2. Restaurar
ansible-playbook ansible/playbooks/restore.yml --limit fgt-centro-dc01 -e "restore_version=20250101_020000"
```

**P: Que diferencia hay entre restore full y merge?**
R: `full` reemplaza toda la config del FortiGate con la del backup.
`merge` solo aplica las secciones del backup que no existen o son diferentes en el dispositivo actual.
Usar `merge` cuando solo se necesita revertir un cambio especifico.

**P: Por que restore pide confirmacion manual?**
R: Los dispositivos primary/secondary son criticos. Restaurar una config incorrecta puede caer toda la red.
Los edge no requieren aprobacion (emergency_rollback.yml).

**P: Que pasa si el restore falla a mitad de camino?**
R: El playbook registra el fallo en audit log y envia alerta PagerDuty.
El FortiGate deberia mantener la config anterior si el restore falla (depende del modelo/firmware).

### Monitoreo

**P: Como agrego un nuevo dispositivo al monitoreo?**
R:
1. Agregar a `ansible/inventory/production/hosts.yml`
2. Agregar/actualizar `group_vars/region_xxx.yml` si es nueva region
3. Si es nuevo modelo, verificar `backup_method` y agregar a matriz en `roles/backup_fortigate/vars/main.yml`
4. Probar: `ansible-playbook ansible/playbooks/backup.yml --limit nuevo-host --check`
5. Ejecutar backup real

**P: Como veo las alertas en tiempo real?**
R: `make monitor` y abrir http://localhost:9093 (Alertmanager) o http://localhost:3000 (Grafana).

**P: Las alertas de Prometheus no se disparan.**
R: Verificar que el exporter corre: `curl http://localhost:9100/metrics | grep fortigate`.
Verificar reglas: en Prometheus UI -> Status -> Rules.

**P: Docker no arranca para el monitoreo.**
R: Asegurar Docker Desktop esta corriendo. Windows: iniciar desde menu.
WSL2: `sudo service docker start`. Linux: `sudo systemctl start docker`.

### Seguridad

**P: El secrets scanner encuentra falsos positivos.**
R: Ajustar `--entropy-threshold` (default 4.5). Agregar patrones a `ignore_list` en secrets_scanner.py.

**P: Cada cuanto rotar credenciales?**
R: SSH keys cada 90 dias, API tokens cada 30 dias, Vault password cada 180 dias.
Hay scripts automatizados para SSH y API.

**P: Que pasa si pierdo el vault password?**
R: No se pueden recuperar las credenciales. Mantener copia offline en gestor de passwords corporativo.
Si ocurre: reconstruir vault.yml con nuevas credenciales.

**P: Como verifico que nadie modifico los backups?**
R: `make verify` ejecuta hash_verifier.py que verifica toda la cadena de Merkle DAG.
Si un archivo fue modificado, el hash no coincidira y la cadena se rompe.

### DR

**P: Cada cuanto se replica al sitio DR?**
R: Automaticamente cada 6 horas, inmediatamente despues de cada backup exitoso.
Via rsync + git push.

**P: Como se si el sitio DR esta funcionando?**
R: `make dr-status` o `.\scripts\powershell\manage.ps1 dr-status`.

**P: Que pasa si el sitio primario se cae completamente?**
R: Ejecutar failover a DR. El DR site toma el control. Los backups siguen corriendo desde ahi.
Cuando el primario vuelva, ejecutar recover para sincronizar.

---

## Problemas Conocidos

### Compatibilidad

| Problema | Causa | Workaround |
|----------|-------|-----------|
| `cli_command` falla en FG-30E con firmware v6.4 | Ansible module requiere Python en el dispositivo (no disponible en v6.4) | Usar `raw` module en vez de `cli_command`. Ver `ansible/roles/backup_fortigate/tasks/via_ssh.yml` |
| API backup falla en FG-60F v7.2.5 | API endpoint `/monitor/system/config/backup` no disponible en v7.2 | Usar method: ssh en vez de api para estos modelos |
| WSL2 no arranca en Windows 10 Home | Windows 10 Home no soporta Hyper-V, requerido por WSL2 | Actualizar a Windows 10 Pro o Windows 11. Alternativa: usar VirtualBox con Ubuntu |

### Errores comunes

| Error | Causa | Solucion |
|-------|-------|----------|
| `UNREACHABLE! => { "changed": false, "msg": "Failed to connect" }` | FortiGate no responde en puerto 22/443 | Verificar conectividad: `ansible {host} -m ping` |
| `Permission denied (publickey)` | SSH key no autorizada en el FortiGate | Agregar clave publica al usuario backup-admin en el FortiGate |
| `vault_password` file not found | `.vault_password` no existe | `cp ansible/vault/.vault_password_template ansible/vault/.vault_password` y poner el password |
| `ERROR! the role 'xxx' was not found` | Coleccion Ansible no instalada | `ansible-galaxy collection install -r ansible/requirements.yml` |
| `Could not find or access 'xxx' on the Ansible Controller` | Path incorrecto en ansible.cfg | Verificar `inventory` y `roles_path` en `ansible/ansible.cfg` |
| `Error: timed out` en backup SSH | Timeout muy bajo (default 30s) | Aumentar `ssh_timeout` en `group_vars/all.yml` |
| `Error: timed out` en backup API | Firewall bloquea puerto 443 | Verificar ACL en el FortiGate y firewall de red |
| Git push falla con `Host key verification failed` | Host key de GitLab no en known_hosts | `ssh-keyscan gitlab.internal.local >> ~/.ssh/known_hosts` |
| `ImportError: No module named 'community'` | Coleccion no instalada | `ansible-galaxy collection install community.general` |
| WSL2: `/opt/fortigate-backup` vacio o no montado | WSL2 no monto el filesystem de Windows | `wsl --shutdown`, luego ejecutar `wsl -d Ubuntu-24.04` de nuevo |

### Logs

```bash
# Logs de Ansible
/var/log/fortigate-backup/
├── ansible-backup-2025-01-15.log      # Output del playbook backup
├── ansible-restore-2025-01-15.log     # Output del playbook restore
├── ansible-validate-2025-01-15.log    # Output del playbook validate
└── ansible-cron-2025-01-15.log        # Output de ejecuciones automaticas

# Logs del sistema
journalctl -u fortigate-backup.service    # Servicio de backup (si configurado)
journalctl -u fortigate-backup.timer      # Timer de backups automaticos

# Logs de monitoreo
make monitor-logs    # Docker Compose logs

# Debug de Ansible
ansible-playbook ansible/playbooks/backup.yml -vvvv    # Maxima verbosidad (4 v's)
```

---

## Referencia Rapida

### Linux
```bash
make help | grep -E "^  [a-z]"    # Listar todos los comandos
```

### Windows
```powershell
.\scripts\powershell\manage.ps1 help    # Listar comandos
```

### Documentacion adicional
| Documento | Contenido |
|-----------|-----------|
| `docs/ARCHITECTURE.md` | Arquitectura detallada, diagramas C4, decisiones tecnicas |
| `docs/SECURITY.md` | Threat model, compliance (ISO 27001, NIST, PCI-DSS), hardening |
| `docs/OPERATIONS.md` | Runbook diario/semanal/mensual, incident response, SOPs |
| `docs/DISASTER_RECOVERY.md` | RPO/RTO, failover manual y automatico, checklists, pruebas |
