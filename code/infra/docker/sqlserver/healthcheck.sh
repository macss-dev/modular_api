#!/usr/bin/env bash
set -euo pipefail

sqlcmd_path=""
sqlcmd_args=()

if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
  sqlcmd_path=/opt/mssql-tools18/bin/sqlcmd
  sqlcmd_args=(-C)
elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
  sqlcmd_path=/opt/mssql-tools/bin/sqlcmd
else
  echo "sqlcmd not found inside SQL Server container" >&2
  exit 1
fi

"${sqlcmd_path}" "${sqlcmd_args[@]}" \
  -S localhost \
  -U sa \
  -P "${MSSQL_SA_PASSWORD}" \
  -Q "SELECT 1" \
  -b \
  -o /dev/null >/dev/null