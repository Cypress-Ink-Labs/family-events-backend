# Database Evidence Scripts

Read-only diagnostic scripts for production performance investigation.

## collect-db-evidence.sql

Run as `postgres` or service_role against a production or staging database:

```bash
psql "$DB_URL" -f scripts/db/collect-db-evidence.sql 2>&1 | tee /tmp/db-evidence-$(date +%Y%m%d).txt
```

**Never commit captured output** — it may contain query text with sensitive data.

### Sections
1. `pg_stat_statements` — top queries by total time and call count
2. `pg_stat_user_indexes` — index usage statistics (low idx_scan = unused index)
3. `pg_stat_user_tables` — table sizes, vacuum/analyze status
4. Constraint pre-validation — must all return 0 before VALIDATE CONSTRAINT migrations
5. EXPLAIN templates — commented out; fill in params before running

### Prerequisites
- `pg_stat_statements` extension must be enabled (Supabase Cloud: enabled by default)
- Run during low-traffic window for accurate buffer hit counts
