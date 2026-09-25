#!/usr/bin/env bash
# Runs the database test suite on a THROWAWAY PostgreSQL (never a Supabase project).
#   TEST_DATABASE_URL=postgres://postgres@localhost:5432/postgres npm run test:db
set -euo pipefail
cd "$(dirname "$0")/.."

URL="${TEST_DATABASE_URL:?Set TEST_DATABASE_URL to an admin connection of a local/CI PostgreSQL}"
case "$URL" in
  *supabase.co*|*supabase.com*|*pooler.supabase*) echo "Refusing to run tests against Supabase: $URL" >&2; exit 1 ;;
esac

DB="pos_test_$$"
BASE="${URL%/*}"
psql "$URL" -qc "create database $DB"
trap 'psql "$URL" -qc "drop database if exists $DB with (force)" >/dev/null' EXIT
T="$BASE/$DB"
run() { psql "$T" -q -v ON_ERROR_STOP=1 "$@"; }
# Quiet on success; print the full psql output when a step fails.
step() { local log; log=$(mktemp); if ! run -f "$1" >"$log" 2>&1; then cat "$log"; exit 1; fi; rm -f "$log"; }

echo "▶ Applying Supabase stub + bundled migrations"
step supabase/tests/supabase_stub.sql
step supabase/setup/01_all_migrations.sql

echo "▶ Smoke test (sales, VAT, returns, exchange, permissions, stock, counts, reports)"
step supabase/tests/smoke_test.sql

echo "▶ Shifts: open, link sales/returns, drawer math, blind close, permissions"
step supabase/tests/shifts_test.sql

echo "▶ Expenses: drawer link, locks, summary, permissions"
step supabase/tests/expenses_test.sql

echo "▶ Sales & Customers 2.0: credit, collections, loyalty, promotions, reservations, QR, permissions"
step supabase/tests/sales_customers_test.sql

echo "▶ Demo data: seed, remove, re-seed"
step supabase/tests/demo_data_test.sql

echo "✓ Database tests passed"
