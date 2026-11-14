-- 01_acid_differences.sql  (MySQL 8)
-- The places where MySQL behaves differently from PostgreSQL. These are classic gotchas.
--
-- Run from the 01-acid-compliance folder. --force keeps going past the EXPECTED errors
-- (MySQL's `source` command would stop at the first one):
--   docker compose exec -T mysql mysql -ulearner -plearner --force -t acid_lab < mysql/00_setup.sql
--   docker compose exec -T mysql mysql -ulearner -plearner --force -t acid_lab < mysql/01_acid_differences.sql

SELECT '=== Gotcha 1: ROLLBACK does nothing on MyISAM (no atomicity) ===' AS '';
START TRANSACTION;
    UPDATE accounts_myisam SET balance = 0;
    UPDATE accounts        SET balance = 0;
ROLLBACK;   -- MySQL prints a warning: "Some non-transactional changed tables couldn't be rolled back"
SHOW WARNINGS;
SELECT 'InnoDB (rolled back):' AS engine, owner, balance FROM accounts
UNION ALL
SELECT 'MyISAM (NOT rolled back):', owner, balance FROM accounts_myisam;


SELECT '=== Gotcha 2: an error does NOT abort the whole transaction ===' AS '';
-- In Postgres, one failed statement poisons the transaction and COMMIT rolls back everything.
-- In MySQL, only the failing STATEMENT is rolled back. The transaction stays open, and
-- COMMIT will happily keep the earlier statements. Your app must ROLLBACK on error itself!
START TRANSACTION;
    UPDATE accounts SET balance = balance + 1000 WHERE owner = 'carol';  -- succeeds
    UPDATE accounts SET balance = balance - 1000 WHERE owner = 'bob';    -- ERROR 3819 (check)
COMMIT;     -- commits carol's +1000. Money was created out of thin air!
SELECT owner, balance FROM accounts ORDER BY id;
UPDATE accounts SET balance = 0 WHERE owner = 'carol';                   -- clean up


SELECT '=== Gotcha 3: DDL causes an implicit COMMIT (no transactional DDL) ===' AS '';
START TRANSACTION;
    UPDATE accounts SET balance = 1 WHERE owner = 'alice';
    CREATE TABLE oops (id INT);     -- silently COMMITS the update above first
ROLLBACK;                           -- too late: alice's update was already committed
SELECT owner, balance FROM accounts WHERE owner = 'alice';   -- 1.00, not 500.00
DROP TABLE oops;
UPDATE accounts SET balance = 500 WHERE owner = 'alice';     -- clean up
-- In PostgreSQL, CREATE/ALTER/DROP TABLE can all be rolled back. This is a big deal for migrations.


SELECT '=== Durability knobs in InnoDB ===' AS '';
SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
-- 1 = flush redo log to disk on every COMMIT (fully durable, the default)
-- 2 = write to OS cache on commit, fsync ~1/sec (survives a mysqld crash, not an OS crash)
-- 0 = write and fsync ~1/sec (can lose ~1 sec of commits on any crash)
SHOW VARIABLES LIKE 'sync_binlog';   -- 1 = binary log also fsync'd per commit
