# MySQL (InnoDB) vs PostgreSQL: ACID differences

Both are ACID-compliant **if you use InnoDB**, which is MySQL's default engine. The behavior
around the edges is different, though, and those edges cause real production bugs.

| Topic | PostgreSQL | MySQL / InnoDB |
| :--- | :--- | :--- |
| Storage engine | One engine, always transactional | **InnoDB** is ACID. **MyISAM** has no transactions, no FKs, and no crash safety |
| Error inside a transaction | Whole transaction is aborted; `COMMIT` becomes `ROLLBACK` | Only the failing statement is undone; `COMMIT` keeps the rest |
| DDL in a transaction | Transactional, so `CREATE`/`ALTER` can be rolled back | **Implicit commit** before and after DDL |
| Default isolation | READ COMMITTED | **REPEATABLE READ** |
| How REPEATABLE READ blocks phantoms | Snapshot; conflicting writes get a serialization error | Snapshot for plain reads, plus **gap/next-key locks** for locking reads and writes (other sessions wait) |
| SERIALIZABLE | True SSI (Serializable Snapshot Isolation); aborts on conflict | Turns plain `SELECT` into `SELECT ... FOR SHARE`, so it locks heavily |
| CHECK constraints | Always enforced | Parsed but **ignored before 8.0.16** |
| Durability log | WAL | Redo log (+ binlog for replication) |
| Durability knob | `synchronous_commit` | `innodb_flush_log_at_trx_commit` (+ `sync_binlog`) |
| Autocommit | On | On |

## Try it

From the `01-acid-compliance` folder (`--force` keeps going past the *expected* errors):

```bash
docker compose exec -T mysql mysql -ulearner -plearner --force -t acid_lab < mysql/00_setup.sql
docker compose exec -T mysql mysql -ulearner -plearner --force -t acid_lab < mysql/01_acid_differences.sql
```

For an interactive shell (needed for the two-session labs below):
`docker compose exec mysql mysql -ulearner -plearner acid_lab`

## Isolation in MySQL: try Lab 2 from the Postgres walkthrough

Open two MySQL sessions and repeat Lab 2 from [../postgres/03_isolation.md](../postgres/03_isolation.md)
**without** setting an isolation level. Because the MySQL default is REPEATABLE READ,
session A will keep seeing 500. Then run `SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;`
in A and repeat it to see the non-repeatable read.

**Gap lock demo** (phantom prevention by blocking):

| Step | Session | Run |
| :-: | :-: | :--- |
| 1 | A | `START TRANSACTION;` `SELECT * FROM accounts WHERE balance > 50 FOR UPDATE;` |
| 2 | B | `INSERT INTO accounts (owner, balance) VALUES ('dave', 1000);` → **blocks** (the gap is locked) |
| 3 | A | `COMMIT;` → B's insert goes through |

PostgreSQL would let B's insert proceed immediately, because `FOR UPDATE` there locks only
existing rows, not gaps.
