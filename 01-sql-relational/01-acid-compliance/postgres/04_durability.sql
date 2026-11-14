-- 04_durability.sql  (PostgreSQL)
-- DURABILITY: once COMMIT returns successfully, the data survives crashes,
-- power loss, and restarts.
--
-- How Postgres does it: the Write-Ahead Log (WAL). Before COMMIT returns, the
-- change is written to the WAL on disk and fsync'd. The actual table files can
-- be updated lazily later; after a crash, Postgres replays the WAL to recover.
--
-- Run: docker compose exec postgres psql -U learner -d acid_lab -f /scripts/04_durability.sql
-- Then follow the "crash test" steps in the README.

\echo '=== Settings that control durability ==='
SHOW fsync;               -- on  = actually flush to disk (NEVER turn off in production)
SHOW synchronous_commit;  -- on  = COMMIT waits for the WAL flush
SHOW wal_level;
SHOW full_page_writes;    -- protects against torn (half-written) pages

\echo ''
\echo '=== Current WAL position: this advances as you write ==='
SELECT pg_current_wal_lsn() AS wal_position_before;

\echo ''
\echo '=== Write a committed marker row ==='
DROP TABLE IF EXISTS durability_test;
CREATE TABLE durability_test (
    id   SERIAL PRIMARY KEY,
    note TEXT,
    at   TIMESTAMPTZ DEFAULT now()
);
INSERT INTO durability_test (note) VALUES ('committed before the crash');  -- autocommit

SELECT pg_current_wal_lsn() AS wal_position_after;

\echo ''
\echo '=== Trade-off: per-transaction relaxed durability ==='
-- synchronous_commit = off returns from COMMIT *before* the WAL flush.
-- Much faster, but a crash can lose the last ~few hundred ms of commits.
-- The database never becomes corrupt; you just lose the newest transactions.
-- Good for: logs, analytics events. Bad for: payments.
BEGIN;
    SET LOCAL synchronous_commit = off;
    INSERT INTO durability_test (note) VALUES ('fast commit, small risk window');
COMMIT;

SELECT * FROM durability_test ORDER BY id;
\echo ''
\echo 'Next: do the crash test in the README (kill the container, restart, check this table).'
