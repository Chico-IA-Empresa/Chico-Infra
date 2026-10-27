#!/bin/sh
set -eu
# PostgreSQL entrypoint invokes this on a NEW disposable data directory only.
# Password files are generated locally; never enable shell tracing.
for password_file in api_password workers_password migrator_password seed_password; do
  test -r "/run/secrets/$password_file" && test -s "/run/secrets/$password_file" || exit 1
done
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=api_password="$(cat /run/secrets/api_password)" \
  --set=workers_password="$(cat /run/secrets/workers_password)" \
  --set=migrator_password="$(cat /run/secrets/migrator_password)" \
  --set=seed_password="$(cat /run/secrets/seed_password)" <<'SQL'
REVOKE ALL ON DATABASE chico_package_test FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE ROLE chico_api LOGIN PASSWORD :'api_password';
CREATE ROLE chico_workers LOGIN PASSWORD :'workers_password';
CREATE ROLE chico_migrator LOGIN PASSWORD :'migrator_password';
CREATE ROLE chico_seed LOGIN PASSWORD :'seed_password';
GRANT CONNECT ON DATABASE chico_package_test TO chico_api, chico_workers, chico_migrator, chico_seed;
GRANT USAGE ON SCHEMA public TO chico_api, chico_workers, chico_migrator, chico_seed;
GRANT CREATE ON SCHEMA public TO chico_migrator;
-- pg_trgm is a trusted extension in PG16; its Alembic migration needs CREATE
-- on this disposable database, never SUPERUSER/CREATEDB/CREATEROLE.
GRANT CREATE ON DATABASE chico_package_test TO chico_migrator;
ALTER DEFAULT PRIVILEGES FOR ROLE chico_migrator IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO chico_api, chico_seed;
ALTER DEFAULT PRIVILEGES FOR ROLE chico_migrator IN SCHEMA public GRANT SELECT ON TABLES TO chico_workers;
ALTER DEFAULT PRIVILEGES FOR ROLE chico_migrator IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO chico_api, chico_workers, chico_seed;
SQL
