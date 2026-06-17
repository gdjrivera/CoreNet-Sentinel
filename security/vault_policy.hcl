# ============================================
# HashiCorp Vault Policy - FortiGate Backup
# ============================================
# Path: policies/fortigate-backup.hcl
# Apply with: vault policy write fortigate-backup fortigate-backup.hcl
# ============================================

# SSH key pairs
path "ssh/*" {
  capabilities = ["read", "list"]
}

path "ssh/fortigate-backup" {
  capabilities = ["read", "list", "create", "update"]
}

# Static secrets (FortiGate credentials)
path "secret/data/fortigate/*" {
  capabilities = ["read", "list"]
}

path "secret/data/fortigate/backup" {
  capabilities = ["read", "list", "create", "update", "delete"]
}

path "secret/metadata/fortigate/*" {
  capabilities = ["read", "list"]
}

# Dynamic secrets (rotating tokens)
path "fortigate/token/*" {
  capabilities = ["read", "list", "create", "update"]
}

# PKI (TLS certificates)
path "pki/*" {
  capabilities = ["read", "list"]
}

path "pki/issue/fortigate-backup" {
  capabilities = ["create", "update"]
}

# KV v2 for application config
path "fortigate-backup/*" {
  capabilities = ["read", "list", "create", "update", "delete"]
}

path "fortigate-backup/metadata/*" {
  capabilities = ["read", "list", "delete"]
}

# Audit logs
path "audit/*" {
  capabilities = ["read", "list"]
}

# Token management (for self-renewal)
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

# System health
path "sys/health" {
  capabilities = ["read"]
}

# Transit (encryption)
path "transit/encrypt/fortigate-backup" {
  capabilities = ["create", "update"]
}

path "transit/decrypt/fortigate-backup" {
  capabilities = ["create", "update"]
}

path "transit/verify/fortigate-backup" {
  capabilities = ["create", "update"]
}

# ============================================
# Approved entities
# ============================================
# entity "fortigate-backup-system" {
#   policies = ["fortigate-backup"]
# }
