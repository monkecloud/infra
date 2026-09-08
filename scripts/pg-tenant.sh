#!/bin/bash
# provision a tenant role + prod/dev databases on the shared CNPG cluster
set -euo pipefail
T="$1"; PW="$2"
PRIMARY=$(kubectl get cluster pg -n postgres -o jsonpath='{.status.currentPrimary}')
echo "primary: $PRIMARY"
X="kubectl exec -i -n postgres $PRIMARY -c postgres -- psql -U postgres -v ON_ERROR_STOP=1"

$X <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${T}') THEN
    CREATE ROLE ${T} LOGIN;
  END IF;
END \$\$;
ALTER ROLE ${T} LOGIN PASSWORD '${PW}';
SELECT 'CREATE DATABASE ${T} OWNER ${T}'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${T}')\gexec
SELECT 'CREATE DATABASE ${T}_dev OWNER ${T}'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${T}_dev')\gexec
REVOKE CONNECT ON DATABASE ${T} FROM PUBLIC;
REVOKE CONNECT ON DATABASE ${T}_dev FROM PUBLIC;
GRANT CONNECT ON DATABASE ${T} TO ${T};
GRANT CONNECT ON DATABASE ${T}_dev TO ${T};
SQL

for db in "${T}" "${T}_dev"; do
  kubectl exec -i -n postgres "$PRIMARY" -c postgres -- \
    psql -U postgres -v ON_ERROR_STOP=1 -d "$db" <<SQL
ALTER SCHEMA public OWNER TO ${T};
SQL
done
echo "OK: ${T} role + ${T}/${T}_dev databases"
