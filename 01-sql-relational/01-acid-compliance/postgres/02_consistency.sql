-- 02_consistency.sql  (PostgreSQL)
-- CONSISTENCY: a transaction moves the database from one valid state to another.
-- "Valid" means every rule you declared still holds: NOT NULL, UNIQUE, CHECK,
-- FOREIGN KEY, and triggers. The DB refuses any change that would break one.
--
-- Note: the database only enforces the rules you TELL it about. "Money is never
-- created or destroyed" is not a constraint here, so keeping it true is the job
-- of your transaction logic (see 01_atomicity.sql).
--
-- Run: docker compose exec postgres psql -U learner -d acid_lab -f /scripts/02_consistency.sql
-- Each statement below should FAIL. Read the error messages.

\echo '=== CHECK: balance can never go negative ==='
UPDATE accounts SET balance = -1 WHERE owner = 'carol';

\echo ''
\echo '=== NOT NULL: every account needs an owner ==='
INSERT INTO accounts (owner, balance) VALUES (NULL, 10);

\echo ''
\echo '=== UNIQUE: no two accounts with the same owner ==='
INSERT INTO accounts (owner, balance) VALUES ('alice', 10);

\echo ''
\echo '=== FOREIGN KEY: cannot transfer to an account that does not exist ==='
INSERT INTO transfers (from_id, to_id, amount) VALUES (1, 999, 5);

\echo ''
\echo '=== FOREIGN KEY: cannot delete an account that has transfer history ==='
DELETE FROM accounts WHERE owner = 'alice';

\echo ''
\echo '=== CHECK across columns: cannot transfer to yourself ==='
INSERT INTO transfers (from_id, to_id, amount) VALUES (1, 1, 5);


\echo ''
\echo '=== Deferred constraints: allowed to be broken mid-transaction, checked at COMMIT ==='
-- Sometimes a rule is temporarily false in the middle of a valid change.
-- Example: swapping two rows' unique "rank" values.
DROP TABLE IF EXISTS leaderboard;
CREATE TABLE leaderboard (
    player TEXT PRIMARY KEY,
    rank   INT  NOT NULL,
    CONSTRAINT unique_rank UNIQUE (rank) DEFERRABLE INITIALLY IMMEDIATE
);
INSERT INTO leaderboard VALUES ('alice', 1), ('bob', 2);

BEGIN;
    SET CONSTRAINTS unique_rank DEFERRED;          -- check at COMMIT, not per statement
    UPDATE leaderboard SET rank = 2 WHERE player = 'alice';  -- two rows have rank 2 right now!
    UPDATE leaderboard SET rank = 1 WHERE player = 'bob';    -- fixed again
COMMIT;                                            -- passes: the final state is valid
SELECT * FROM leaderboard ORDER BY rank;

DROP TABLE leaderboard;

\echo ''
\echo 'Data is unchanged by all the failed statements above:'
SELECT owner, balance FROM accounts ORDER BY id;
