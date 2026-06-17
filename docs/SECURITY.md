# Security - FortiGate Backup System

## Modelo de Amenazas

| Amenaza | Impacto | Probabilidad | Mitigación |
|---------|---------|-------------|------------|
| Acceso no autorizado al orquestador | Crítico | Baja | RBAC, MFA, bastion host |
| Intercepción de configuraciones en tránsito | Alto | Baja | SSH ed25519, TLS 1.3 |
| Filtración de credenciales en Git | Crítico | Media | git-crypt, pre-commit hooks |
| Modificación de backups almacenados | Alto | Baja | Hash chain, WORM en S3 |
| Ataque DDoS al orquestador | Medio | Baja | Rate limiting, fail2ban |
| Pérdida de datos por desastre | Alto | Media | DR site, replicación S3 CRR |

## Gestión de Credenciales

### Ansible Vault

```bash
# Crear vault
ansible-vault create ansible/vault/vault.yml

# Editar vault
ansible-vault edit ansible/vault/vault.yml

# Usar en playbook
ansible-playbook playbooks/backup.yml --vault-password-file .vault_password
```

### HashiCorp Vault (Recomendado para producción)

```hcl
path "secret/data/fortigate/*" {
  capabilities = ["read", "list"]
}
```

### Rotación Automática

- **SSH Keys**: Cada 90 días (script: `rotate_credentials.sh`)
- **API Tokens**: Cada 30 días (script: `rotate_credentials.sh`)
- **Vault Password**: Cada 180 días

## Cifrado

### En Tránsito

| Protocolo | Configuración |
|-----------|--------------|
| SSH | ed25519 keys, host key validation |
| HTTPS | TLS 1.3, ciphers perfect forward secrecy |
| Git | SSH transport (no HTTPS) |
| API | mTLS opcional para entornos críticos |

### En Reposo

| Capa | Método | Implementación |
|------|--------|---------------|
| Repositorio Git | git-crypt (AES-256-GCM) | `setup_git_crypt.sh` |
| Archivos individuales | SOPS / age | Archivos .enc |
| Backup S3 | SSE-S3 o SSE-KMS | Bucket policy |
| Backup inmutable | S3 Object Lock (WORM) | Compliance mode |
| Base de datos | TDE (Transparent Data Encryption) | PostgreSQL |

## Control de Acceso

### RBAC en AWX

| Rol | Permisos |
|-----|----------|
| Superadmin | Full access, auditoría |
| Network Admin | Ejecutar jobs, ver resultados |
| Security Auditor | Solo lectura, ver configuraciones |
| NOC | Ver dashboards, recibir alertas |

### Branch Protection (Git)

- `main`: Solo merge via MR/PR con 2 approvals
- GPG signing obligatorio
- Requerir CI passing
- No permitir push directo

## Prevención de Ataques

### Inyección (SSH/API)
- Ansible usa parámetros tipados
- No interpolación directa en comandos shell
- Validación de entrada en scripts Python

### DDoS al Orquestador
- Rate limiting por host en AWX
- `max_forks` controlado (50)
- Colas de jobs separadas por región
- fail2ban en SSH

### Man-in-the-Middle
- Host key checking en Ansible
- CA firmada para certificados
- Known hosts pre-configurados

### Data Leakage en Git
- `git-secrets` / `trufflehog` en pipeline
- Pre-commit hooks con detect-secrets
- git-crypt para archivos sensibles
- `.gitattributes` con patrones de cifrado

## Compliance

### Estándares Soportados

| Estándar | Controles |
|----------|-----------|
| NIST CSF | ID.BE-5, PR.DS-4, PR.DS-8, DE.CM-4 |
| PCI DSS | 7.1, 7.2, 10.2, 10.3, 10.5 |
| SOX | Section 302, 404 |
| GDPR | Article 5, 32 |
| ISO 27001 | A.9, A.10, A.12, A.16 |

### Auditoría

```bash
# Compliance check
python3 security/audit/compliance_check.py --profile enhanced

# Verificar integridad
python3 scripts/python/hash_verifier.py --verify-chain

# Escanear secrets
python3 scripts/python/secrets_scanner.py --dir /opt/backups --ci-mode
```
