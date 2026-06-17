# Disaster Recovery - FortiGate Backup System

## Estrategia de Recuperación

### RPO y RTO

| Métrica | Objetivo | Real |
|---------|----------|------|
| RPO (Recovery Point Objective) | 6 horas | 6 horas (backups incrementales) |
| RTO (Recovery Time Objective) | 2 horas | ~30 minutos (failover automático) |
| WRT (Work Recovery Time) | 1 hora | ~15 minutos (verificación posterior) |

### Arquitectura DR

```
Primary Site (DC Centro)
├── AWX (active)
├── Backup Storage (activo)
├── Git (origin)
└── PostgreSQL (primary)
        │
        │ (replicación síncrona)
        ▼
DR Site (DC Norte)
├── AWX (standby)
├── Backup Storage (réplica)
├── Git (mirror)
└── PostgreSQL (standby)
```

## Procedimientos de Failover

### 1. Failover Manual (Planificado)

```bash
# Paso 1: Verificar estado del sitio primario
./scripts/bash/dr_failover.sh --status

# Paso 2: Sincronizar datos actuales
./scripts/bash/dr_failover.sh \
    --replicate-to backup@dr-site:/opt/backups/fortigates

# Paso 3: Promover DR site
./scripts/bash/dr_failover.sh \
    --failover-to dr-site.internal.local

# Paso 4: Verificar integridad
python3 scripts/python/hash_verifier.py \
    --backup-dir /opt/backups/fortigates \
    --verify-chain
```

### 2. Failover Automático (No Planificado)

```yaml
# Alertmanager rule
- alert: SiteDown
  expr: fortigate_overall_status == 0
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Primary backup site is DOWN"
```

### 3. Failover de Base de Datos

```bash
# Promover standby a primary
pg_ctl promote -D /var/lib/postgresql/standby

# Reconfigurar aplicaciones
psql -c "SELECT pg_promote()" -h dr-site

# Verificar replicación
psql -c "SELECT * FROM pg_stat_replication"
```

## Procedimientos de Recuperación

### 1. Recuperación de Datos

```bash
# Desde Git (versiones recientes)
git -C /opt/backups/fortigates checkout <commit-hash>
git -C /opt/backups/fortigates restore --staged .

# Desde S3 (backups fríos)
aws s3 sync s3://fortigate-backups-dr/ /opt/backups/fortigates/

# Desde backup local (último full)
cp -a /opt/backups/fortigates/ /opt/backups/fortigates-restored/
```

### 2. Recuperación del Orquestador

```bash
# Restaurar AWX desde backup
awx-manage restore --backup-file /backup/awx-backup-20250101.tar

# Reconfigurar inventarios
ansible-playbook ansible/playbooks/site.yml --tags=configure-awx

# Verificar conectividad
ansible all -i ansible/inventory/production/hosts.yml -m ping
```

### 3. Recuperación de Configuración de Red

```bash
# Restaurar config en sandbox primero
ansible-playbook ansible/playbooks/restore.yml \
    --limit fgt-centro-sandbox \
    -e "restore_version=20250101_020000 config_merge=true"

# Validar configuración restaurada
python3 scripts/python/config_validator.py --config-dir /ruta/config

# Aplicar a producción
ansible-playbook ansible/playbooks/emergency_rollback.yml \
    --limit fgt-centro-dc01 \
    -e "restore_version=20250101_020000"
```

## Plan de Pruebas

### Pruebas Mensuales

```bash
# 1. Restauración en sandbox
ansible-playbook ansible/playbooks/restore.yml \
    --limit fgt-centro-sandbox \
    -e "restore_version=$(date +%Y%m%d_020000)"

# 2. Verificar reachabilidad posterior
python3 scripts/python/health_check.py --host fgt-centro-sandbox --port 22

# 3. Verificar integridad del backup
python3 scripts/python/hash_verifier.py --backup-dir /opt/backups/fortigates --verify-chain
```

### Pruebas Trimestrales

```bash
# 1. Simular failover completo
./scripts/bash/dr_failover.sh --failover-to dr-site.internal.local

# 2. Ejecutar backup desde DR site
make backup

# 3. Restaurar primary
./scripts/bash/dr_failover.sh --recover

# 4. Verificar consistencia
python3 scripts/python/report_generator.py \
    --backup-dir /opt/backups/fortigates \
    --range 30d \
    --format json
```

## Documentación de Incidentes

### Formato de Reporte

```yaml
incident_id: "DR-2025-001"
date: "2025-01-15"
severity: "critical"
type: "site_failover"
trigger: "primary_site_unreachable"

timeline:
  - "02:00 UTC - Backup job fails for all devices"
  - "02:05 UTC - PagerDuty alert received"
  - "02:10 UTC - DR failover initiated"
  - "02:25 UTC - DR site active, backups resuming"
  - "02:45 UTC - All backups verified in DR site"
  - "03:30 UTC - Primary site restored"
  - "03:45 UTC - Failback completed"

actions_taken:
  - "Failed over to DR site (fgt-dr-01.internal.local)"
  - "Executed backup from DR location"
  - "Validated integrity of all configs"
  - "Replicated data back to primary"
  - "Failed back to primary site"

root_cause: "Network outage affecting primary data center"
resolution: "ISP route restored after BGP convergence"
lessons_learned: "Add redundant internet connection to primary site"

backup_versions_affected: []
data_loss: false
rpo_met: true
rto_met: true
```
