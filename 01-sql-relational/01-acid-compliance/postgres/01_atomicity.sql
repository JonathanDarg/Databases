-- 01_atomicity.sql  (PostgreSQL)
-- ATOMICITY: a transaction is all-or-nothing. Either every statement in it
-- takes effect, or none of them do.
--
-- Run: docker compose exec postgres psql -U learner -d acid_lab -f /scripts/01_atomicity.sql
-- (Errors printed below are EXPECTED. They are the point of the demo.)

\echo '=== Starting state ==='
SELECT owner, balance FROM accounts ORDER BY id;


\echo ''
\echo '=== Demo 1: a successful transfer (alice -> bob, 50) ==='
BEGIN;
    UPDATE accounts SET balance = balance - 50 WHERE owner = 'alice';
    UPDATE accounts SET balance = balance + 50 WHERE owner = 'bob';
    INSERT INTO transfers (from_id, to_id, amount)
        SELECT a.id, b.id, 50 FROM accounts a, accounts b
        WHERE a.owner = 'alice' AND b.owner = 'bob';
COMMIT;
SELECT owner, balance FROM accounts ORDER BY id;


\echo ''
\echo '=== Demo 2: a transfer that fails halfway (bob -> carol, 1000) ==='
\echo 'Step 1 credits carol. Step 2 would push bob below 0 and violates the CHECK.'
BEGIN;
    UPDATE accounts SET balance = balance + 1000 WHERE owner = 'carol';  -- succeeds...
    SELECT owner, balance FROM accounts WHERE owner = 'carol';           -- carol has 1000 INSIDE the txn
    UPDATE accounts SET balance = balance - 1000 WHERE owner = 'bob';    -- ERROR: check constraint
    -- Postgres has now marked the transaction "aborted". Any further statement errors with:
    --   "current transaction is aborted, commands ignored until end of transaction block"
    SELECT 'this will not run';
COMMIT;   -- on an aborted transaction, COMMIT actually performs a ROLLBACK

\echo 'After the failed transaction: carol did NOT keep the 1000.'
SELECT owner, balance FROM accounts ORDER BY id;


\echo ''
\echo '=== Demo 3: explicit ROLLBACK (you change your mind) ==='
BEGIN;
    DELETE FROM transfers;
    UPDATE accounts SET balance = 0;
    SELECT owner, balance FROM accounts ORDER BY id;  -- everyone is broke (inside the txn)
ROLLBACK;
SELECT owner, balance FROM accounts ORDER BY id;      -- nothing happened


\echo ''
\echo '=== Demo 4: SAVEPOINTs, partial rollback inside one transaction ==='
BEGIN;
    UPDATE accounts SET balance = balance - 10 WHERE owner = 'alice';
    UPDATE accounts SET balance = balance + 10 WHERE owner = 'carol';
    SAVEPOINT after_first_gift;

    UPDATE accounts SET balance = balance - 9999 WHERE owner = 'alice';  -- ERROR
    ROLLBACK TO SAVEPOINT after_first_gift;   -- undo only back to the savepoint;
                                              -- the transaction is usable again
COMMIT;
\echo 'The 10 gift was kept; the 9999 attempt was undone.'
SELECT owner, balance FROM accounts ORDER BY id;

\echo ''
\echo 'Total money should still be 600.00:'
SELECT sum(balance) AS total FROM accounts;
