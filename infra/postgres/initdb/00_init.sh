#!/usr/bin/env bash
# ============================================================================
# Postgres initdb hook.
#
# Runs on first database initialization and is rerun by scripts/start.* before
# database clients start. Reapplying it rotates role passwords from the current
# environment while preserving all existing database data.
# Creates the least-privilege application roles used by:
#   - account-service  (account schema, identity model)
#   - prompt-service   (prompt  schema, Standardized Prompt registry)
# and grants only the privileges each one needs against its own schema.
#
# Inputs (from docker-compose env):
#   POSTGRES_USER         (already created as superuser by the official image)
#   POSTGRES_DB           (already created by the official image)
#   ACCOUNT_DB_USER       login role for account-service
#   ACCOUNT_DB_PASSWORD   password for that role
#   PROMPT_DB_USER        login role for prompt-service
#   PROMPT_DB_PASSWORD    password for that role
#
# Each service runs Flyway migrations under its OWN role at boot, so the
# role needs CREATE on its schema. Production-only deployments can split
# migration vs runtime roles per service; for now we treat the local stack
# as the documented baseline. Schemas are strictly siloed: the account
# role has no privileges on the prompt schema and vice versa.
# ============================================================================
set -euo pipefail

DB_MODE="${DB_MODE:-full}"  # full | operational | knowledge
echo "[initdb] Running in DB_MODE: $DB_MODE"

# Ensure the target database exists (useful when DB name is changed on an existing cluster)
if [[ "${POSTGRES_DB:-}" != "postgres" ]]; then
    echo "[initdb] Ensuring database $POSTGRES_DB exists..."
    DB_EXISTS=$(psql -tAc "SELECT 1 FROM pg_database WHERE datname='$POSTGRES_DB';" --username "$POSTGRES_USER" --dbname "postgres" 2>/dev/null || echo "0")
    if [[ "$DB_EXISTS" != "1" ]]; then
        echo "[initdb] Database $POSTGRES_DB does not exist. Creating..."
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" -c "CREATE DATABASE $POSTGRES_DB;"
    fi
fi

if [[ "$DB_MODE" == "full" || "$DB_MODE" == "operational" ]]; then
    # pgcrypto is required by both schemas (gen_random_uuid()). Create it
    # once up-front under the superuser so neither application role needs
    # the extension privilege.
    psql -v ON_ERROR_STOP=1 \
         --username "$POSTGRES_USER" \
         --dbname  "$POSTGRES_DB" <<-EOSQL
        CREATE EXTENSION IF NOT EXISTS pgcrypto;
EOSQL
fi

# ---------------- account-service role + schema ----------------
if [[ "$DB_MODE" == "full" || "$DB_MODE" == "operational" ]]; then
    if [[ -n "${ACCOUNT_DB_USER:-}" && -n "${ACCOUNT_DB_PASSWORD:-}" ]]; then
        psql -v ON_ERROR_STOP=1 \
             --username "$POSTGRES_USER" \
             --dbname  "$POSTGRES_DB" <<-EOSQL
            -- Least-privilege application role. LOGIN required (CREATEROLE/SUPERUSER not).
            DO \$\$
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${ACCOUNT_DB_USER}') THEN
                    CREATE ROLE ${ACCOUNT_DB_USER} WITH LOGIN;
                END IF;
            END
            \$\$;
            ALTER ROLE ${ACCOUNT_DB_USER} WITH LOGIN PASSWORD '${ACCOUNT_DB_PASSWORD}';

            -- The role owns the account schema (so Flyway can create tables) but is
            -- not superuser; broader cluster privileges remain with $POSTGRES_USER.
            CREATE SCHEMA IF NOT EXISTS account AUTHORIZATION ${ACCOUNT_DB_USER};
            GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO ${ACCOUNT_DB_USER};
            GRANT USAGE, CREATE ON SCHEMA account TO ${ACCOUNT_DB_USER};
EOSQL
        echo "[initdb] account role and schema ready."
    else
        echo "[initdb] ACCOUNT_DB_USER / ACCOUNT_DB_PASSWORD not set; skipping account bootstrap."
    fi
fi

# ---------------- prompt-service role + schema ----------------
if [[ "$DB_MODE" == "full" || "$DB_MODE" == "operational" ]]; then
    if [[ -n "${PROMPT_DB_USER:-}" && -n "${PROMPT_DB_PASSWORD:-}" ]]; then
        psql -v ON_ERROR_STOP=1 \
             --username "$POSTGRES_USER" \
             --dbname  "$POSTGRES_DB" <<-EOSQL
            -- Least-privilege application role for the Standardized Prompt
            -- registry. Mirrors the account-service bootstrap above: same
            -- LOGIN posture, no broader cluster privileges.
            DO \$\$
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PROMPT_DB_USER}') THEN
                    CREATE ROLE ${PROMPT_DB_USER} WITH LOGIN;
                END IF;
            END
            \$\$;
            ALTER ROLE ${PROMPT_DB_USER} WITH LOGIN PASSWORD '${PROMPT_DB_PASSWORD}';

            -- The role owns the prompt schema (so Flyway can create tables and
            -- indexes from V1__standardized_prompt.sql) but is not superuser;
            -- account-service has no privileges here, and vice versa.
            CREATE SCHEMA IF NOT EXISTS prompt AUTHORIZATION ${PROMPT_DB_USER};
            GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO ${PROMPT_DB_USER};
            GRANT USAGE, CREATE ON SCHEMA prompt TO ${PROMPT_DB_USER};
EOSQL
        echo "[initdb] prompt role and schema ready."
    else
        echo "[initdb] PROMPT_DB_USER / PROMPT_DB_PASSWORD not set; skipping prompt bootstrap."
    fi
fi

# ---- Extensions required for Graph-RAG ----
if [[ "$DB_MODE" == "full" || "$DB_MODE" == "knowledge" ]]; then
    psql -v ON_ERROR_STOP=1 \
         --username "$POSTGRES_USER" \
         --dbname  "$POSTGRES_DB" <<-EOSQL
        CREATE EXTENSION IF NOT EXISTS age;
        CREATE EXTENSION IF NOT EXISTS vector;

        -- Load AGE into the session search path for the current connection
        LOAD 'age';
        SET search_path = ag_catalog, "\$user", public;
EOSQL

    # ---- graphrag-service role + schema ----
    if [[ -n "${GRAPHRAG_DB_USER:-}" && -n "${GRAPHRAG_DB_PASSWORD:-}" ]]; then
        psql -v ON_ERROR_STOP=1 \
             --username "$POSTGRES_USER" \
             --dbname  "$POSTGRES_DB" <<-EOSQL
            DO \$\$
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${GRAPHRAG_DB_USER}') THEN
                    CREATE ROLE ${GRAPHRAG_DB_USER} WITH LOGIN;
                END IF;
            END
            \$\$;
            ALTER ROLE ${GRAPHRAG_DB_USER} WITH LOGIN PASSWORD '${GRAPHRAG_DB_PASSWORD}';

            CREATE SCHEMA IF NOT EXISTS graphrag AUTHORIZATION ${GRAPHRAG_DB_USER};
            GRANT CONNECT, CREATE ON DATABASE ${POSTGRES_DB} TO ${GRAPHRAG_DB_USER};
            GRANT USAGE, CREATE ON SCHEMA graphrag TO ${GRAPHRAG_DB_USER};

            -- Grant AGE catalog access so the graphrag role can execute Cypher
            GRANT USAGE ON SCHEMA ag_catalog TO ${GRAPHRAG_DB_USER};
            GRANT SELECT ON ALL TABLES IN SCHEMA ag_catalog TO ${GRAPHRAG_DB_USER};
EOSQL
        echo "[initdb] graphrag role and schema ready."
    else
        echo "[initdb] GRAPHRAG_DB_USER / GRAPHRAG_DB_PASSWORD not set; skipping graphrag bootstrap."
    fi
fi
