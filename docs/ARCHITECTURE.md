# Architecture - FortiGate Backup System

## System Overview

Sistema centralizado de respaldo automático para configuraciones de FortiGate a nivel nacional. Orquestado con Ansible AWX, almacenamiento versionado en Git, respaldo inmutable en S3, y monitoreo en tiempo real con Prometheus/Grafana.

## Componentes Core

### 1. Plano de Orquestación

```
AWX/Tower (Scheduler)
├── Job Template: Full Backup (02:00 UTC)
├── Job Template: Incremental Backup (cada 6h)
├── Job Template: Validate Configs
└── Job Template: Emergency Rollback
    │
    ▼
Ansible Runner
├── Inventory Dinámico (YAML + CMDB)
├── Roles modulares
│   ├── backup_fortigate (SSH/API)
│   ├── validate_config (Integridad + Seguridad)
│   ├── git_sync (Versionado)
│   ├── restore_fortigate (Recuperación)
│   └── notify (Alertas multi-canal)
└── Vault (Credenciales cifradas)
```

### 2. Plano de Datos

```
FortiGates (SSH/API)
    │
    ▼
Backup Directory (/opt/backups/fortigates)
├── {hostname}/
│   ├── {YYYY-MM-DD}/
│   │   ├── {hostname}_full_config.conf
│   │   ├── {hostname}_metadata.json
│   │   └── validation_report.json
│   └── ...
├── manifest_{date}.json
└── .hash_chain.json
    │
    ├──▶ Git Repository (Versionado + Diff)
    │     └── Remote: gitlab.internal.local (git-crypt)
    │
    └──▶ S3/MinIO (Backup inmutable - WORM)
          └── Retention: 365 días (Object Lock)
```

### 3. Plano de Monitoreo

```
Prometheus
├── Node Exporter (métricas del servidor)
├── Pushgateway (métricas de backup)
├── Postgres Exporter (métricas BD)
└── Reglas de alerta personalizadas
    │
    ├──▶ Grafana (Dashboards)
    └──▶ Alertmanager
          ├── Slack (#network-backups)
          ├── PagerDuty (critical)
          └── Email (daily digest)
```

## Flujo de Backup (diario)

```
02:00 UTC AWX dispara job
    │
    ▼
Ansible resuelve inventario
    │
    ▼
Para cada FortiGate (paralelo, forks=50):
├── SSH: show full-configuration
│   └── o API: GET /api/v2/monitor/system/config/backup
├── Validar: tamaño, hash, secciones requeridas
├── Guardar: {hostname}/{date}/{hash}_config.conf
├── Metadata: timestamp, tamaño, hash → PostgreSQL
└── Notificar: éxito/fallo/cambio detectado
    │
    ▼
Post-procesamiento:
├── Hash chain (SHA-256 + Merkle DAG)
├── Secrets scanning (trufflehog)
├── Git commit + push
├── S3 sync (backup frío)
└── Reporte diario (HTML/JSON)
```

## Estrategia de Escalabilidad

| Componente | Estrategia |
|-----------|-----------|
| Ansible Runner | `forks=50`, `serial=10`, strategy `linear` |
| AWX | HA multi-nodo, colas de jobs separadas por región |
| Git | Shallow clone, gc periódico, tags por backup |
| S3 | Cross-region replication, Lifecycle policies |
| Monitoreo | Prometheus federated, Grafana HA |
| Base de datos | PostgreSQL read-replicas para reportes |

## Seguridad por Capas

1. **Red**: Bastion host, port knocking, ACLs por origen IP
2. **Transporte**: SSH con ed25519, TLS 1.3, mTLS para API
3. **Almacenamiento**: git-crypt + AES-256, S3 SSE-KMS, WORM
4. **Credenciales**: Ansible Vault + HashiCorp Vault, rotación automática
5. **Código**: Pre-commit hooks, secrets scanning, firmas GPG
6. **Monitoreo**: Detección de anomalías, alertas de integridad
