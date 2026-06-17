# Operations - FortiGate Backup System

## Daily Operations

### Verificar Estado del Sistema

```bash
# Estado general
make status

# Health check
make health

# Verificar backups del día
ls -la /opt/backups/fortigates/*/$(date +%Y-%m-%d)/

# Verificar Git
git -C /opt/backups/fortigates log --oneline -5
```

### Ejecutar Backup Manual

```bash
# Full backup
make backup

# Backup por región
make backup-region R=centro

# Backup single device
ansible-playbook ansible/playbooks/backup.yml \
    --limit fgt-centro-dc01
```

### Validar Configuraciones

```bash
# Validar todos los backups
make validate

# Verificar integridad (hash chain)
make verify

# Validar inventario
make validate-inventory
```

## Weekly Operations

### Reportes

```bash
# Reporte diario HTML
make report

# Reporte manual con rango
python3 scripts/python/report_generator.py \
    --backup-dir /opt/backups/fortigates \
    --range 7d \
    --format html \
    --output reports/weekly-report.html
```

### Seguridad

```bash
# Escanear secrets en backups
make security

# Compliance check
make compliance

# Verificar caducidad de certificados
python3 scripts/python/health_check.py \
    --host bastion.internal.local --port 443
```

## Monthly Operations

### Rotación de Credenciales

```bash
# Rotar SSH keys y API tokens
make security-rotate

# Rotar solo API tokens
./scripts/bash/rotate_credentials.sh --rotate-api

# Rotar solo SSH keys (dry-run)
./scripts/bash/rotate_credentials.sh --rotate-ssh --dry-run
```

### Limpieza

```bash
# Limpiar backups antiguos (>90 días)
make clean-backups

# Compactar repositorio Git
git -C /opt/backups/fortigates gc --aggressive
```

### Pruebas de Restauración

```bash
# Restaurar en staging
ansible-playbook ansible/playbooks/restore.yml \
    --limit fgt-centro-sandbox \
    -e "restore_version=20250101_020000 config_merge=true"

# Restauración completa (con aprobación)
ansible-playbook ansible/playbooks/restore.yml \
    --limit fgt-norte-suc01 \
    -e "restore_version=20250101_020000"
```

## Incident Response

### Falla de Backup

```bash
# 1. Verificar estado
make health

# 2. Revisar logs
make logs

# 3. Verificar conectividad
ansible all -i ansible/inventory/production/hosts.yml \
    --vault-password-file ansible/vault/.vault_password \
    -m ping --limit fgt-centro-dc01

# 4. Re-ejecutar backup del dispositivo fallido
ansible-playbook ansible/playbooks/backup.yml \
    --limit fgt-centro-dc01
```

### Recuperación ante Desastre

```bash
# 1. Verificar estado DR
make dr-status

# 2. Failover a DR site
./scripts/bash/dr_failover.sh \
    --failover-to dr-site.internal.local

# 3. Verificar integridad en DR
python3 scripts/python/hash_verifier.py \
    --backup-dir /opt/backups/fortigates \
    --verify-chain

# 4. Recuperar primary cuando esté disponible
./scripts/bash/dr_failover.sh --recover
```

### Restauración de Configuración

```bash
# 1. Identificar versión
git -C /opt/backups/fortigates tag -l 'backup-*' | sort -r | head -5

# 2. Restaurar (edge - auto-aprobado)
ansible-playbook ansible/playbooks/emergency_rollback.yml \
    --limit fgt-centro-suc01 \
    -e "restore_version=20250101_020000"

# 3. Restaurar (primary - requiere aprobación)
ansible-playbook ansible/playbooks/restore.yml \
    --limit fgt-centro-dc01 \
    -e "restore_version=20250101_020000"
```

## CI/CD Pipeline

### Pipeline Stages

```
validate → security-scan → test → backup → verify → report → deploy
```

### Ejecutar Pipeline Manual

```bash
# GitLab CI
curl -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "https://gitlab.internal.local/api/v4/projects/1/trigger/pipeline" \
    -d "ref=main&token=$CI_TRIGGER_TOKEN"

# GitHub Actions
gh workflow run backup-pipeline.yml \
    -f environment=production \
    -f region=centro
```

## Monitoreo

### Dashboards

| Dashboard | URL | Propósito |
|-----------|-----|-----------|
| Grafana | http://localhost:3000 | Métricas de backup |
| Prometheus | http://localhost:9090 | Consultas ad-hoc |
| Alertmanager | http://localhost:9093 | Gestión de alertas |

### Alertas Críticas

| Alerta | Condición | Canal |
|--------|-----------|-------|
| BackupJobFailed | Backup falla | PagerDuty + Slack |
| DeviceUnreachable | Health check falla | PagerDuty |
| DiskSpaceLow | <20% free | PagerDuty |
| SecretsFound | Secrets detectados | Slack + Email |
| ComplianceViolation | Score <80% | Slack |

## Troubleshooting

### Problemas Comunes

| Síntoma | Causa | Solución |
|---------|-------|----------|
| Backup falla por timeout | Dispositivo no responde | Verificar reachability, aumentar timeout |
| Git push falla | SSH key no autorizada | Verificar deploy key en GitLab |
| Validación falla | Config mal formada | Revisar validation_report.json |
| Database connection error | PostgreSQL caído | systemctl restart postgresql |
| Secrets scan false positives | Pattern match incorrecto | Actualizar SECRET_PATTERNS |
| AWX job no arranca | Recursos insuficientes | Verificar forks y colas |
