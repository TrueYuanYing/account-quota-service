#!/bin/sh
# Initial installation only. Existing instances need reviewed versioned upgrades.
set -eu
exists=$(psql -At -v ON_ERROR_STOP=1 -c "SELECT to_regnamespace('iko') IS NOT NULL")
if [ "$exists" != "f" ]; then echo 'Refusing: iko schema already exists; use reviewed upgrades.' >&2; exit 1; fi
ready=$(psql -At -v ON_ERROR_STOP=1 -c "SELECT to_regclass('auth.users') IS NOT NULL")
if [ "$ready" != "t" ]; then echo 'Start GoTrue and wait for auth.users first.' >&2; exit 1; fi
for migration in /migrations/*.sql; do psql -v ON_ERROR_STOP=1 -f "$migration"; done
psql -v ON_ERROR_STOP=1 -f /deploy/grants.sql
