-- 00_setup.sql  (MySQL 8)
-- Same bank as the Postgres lab, plus a MyISAM copy to show what NON-ACID looks like.
--
-- Run (from the 01-acid-compliance folder):
--   docker compose exec mysql sh -c "mysql -ulearner -plearner -t acid_lab < /scripts/00_setup.sql"
-- or inside an interactive mysql shell:  source /scripts/00_setup.sql

DROP TABLE IF EXISTS transfers;
DROP TABLE IF EXISTS accounts;
DROP TABLE IF EXISTS accounts_myisam;

CREATE TABLE accounts (
    id      INT AUTO_INCREMENT PRIMARY KEY,
    owner   VARCHAR(50)    NOT NULL UNIQUE,
    balance DECIMAL(12, 2) NOT NULL,
    CONSTRAINT balance_non_negative CHECK (balance >= 0)  -- enforced only since MySQL 8.0.16!
) ENGINE = InnoDB;                                        -- InnoDB = transactional, ACID

CREATE TABLE transfers (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    from_id    INT            NOT NULL,
    to_id      INT            NOT NULL,
    amount     DECIMAL(12, 2) NOT NULL CHECK (amount > 0),
    created_at TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (from_id) REFERENCES accounts(id),
    FOREIGN KEY (to_id)   REFERENCES accounts(id)
) ENGINE = InnoDB;

-- Same table on the MyISAM engine: NO transactions, NO foreign keys, NO crash safety.
CREATE TABLE accounts_myisam (
    id      INT AUTO_INCREMENT PRIMARY KEY,
    owner   VARCHAR(50)    NOT NULL UNIQUE,
    balance DECIMAL(12, 2) NOT NULL
) ENGINE = MyISAM;

INSERT INTO accounts        (owner, balance) VALUES ('alice', 500), ('bob', 100), ('carol', 0);
INSERT INTO accounts_myisam (owner, balance) VALUES ('alice', 500), ('bob', 100), ('carol', 0);

SELECT * FROM accounts ORDER BY id;
SELECT @@transaction_isolation AS default_isolation;  -- REPEATABLE-READ (Postgres: read committed)
