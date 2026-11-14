-- 00_setup.sql  (PostgreSQL)
-- A tiny bank. Re-run this any time to reset the lab to a known state.
--
-- Run: docker compose exec postgres psql -U learner -d acid_lab -f /scripts/00_setup.sql

DROP TABLE IF EXISTS transfers;
DROP TABLE IF EXISTS accounts;

CREATE TABLE accounts (
    id      SERIAL PRIMARY KEY,
    owner   TEXT           NOT NULL UNIQUE,
    balance NUMERIC(12, 2) NOT NULL CHECK (balance >= 0)   -- a business rule the DB enforces
);

CREATE TABLE transfers (
    id         SERIAL PRIMARY KEY,
    from_id    INT            NOT NULL REFERENCES accounts(id),
    to_id      INT            NOT NULL REFERENCES accounts(id),
    amount     NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    created_at TIMESTAMPTZ    NOT NULL DEFAULT now(),
    CHECK (from_id <> to_id)
);

INSERT INTO accounts (owner, balance) VALUES
    ('alice', 500.00),
    ('bob',   100.00),
    ('carol',   0.00);

SELECT * FROM accounts ORDER BY id;
SELECT sum(balance) AS total_money_in_bank FROM accounts;  -- remember this number: 600.00
