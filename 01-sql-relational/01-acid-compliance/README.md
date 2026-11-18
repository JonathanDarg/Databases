# 01 · ACID Compliance

> **Goal:** understand what a database *promises* when it says "committed", and see each
> promise hold (or break) with your own eyes in PostgreSQL and MySQL.

## What is a transaction?

A **transaction** is a group of SQL statements that the database treats as **one unit of work**.

```sql
BEGIN;
  UPDATE accounts SET balance = balance - 50 WHERE owner = 'alice';
  UPDATE accounts SET balance = balance + 50 WHERE owner = 'bob';
COMMIT;
```

If the server crashes between those two `UPDATE`s, what should happen? Is alice out $50
and bob never got it? **ACID** is the set of guarantees that answers that question.

## The four properties

| | Property | The promise | The mechanism | Failure it prevents |
| :-: | :--- | :--- | :--- | :--- |
| **A** | **Atomicity** | All statements happen, or none do | Undo info / MVCC row versions; `ROLLBACK` | Half-finished transfers |
| **C** | **Consistency** | Every commit leaves all declared rules true | `CHECK`, `NOT NULL`, `UNIQUE`, `FOREIGN KEY`, triggers | Negative balances, orphan rows |
| **I** | **Isolation** | Concurrent transactions don't see each other's half-done work | MVCC snapshots + locks; isolation levels | Dirty reads, lost updates, write skew |
| **D** | **Durability** | Once `COMMIT` returns, the data survives a crash | Write-Ahead Log (PG) / redo log (InnoDB) + `fsync` | "We said it saved, but it's gone" |

### Mental model

- **Atomicity** is about *failure*: "if something goes wrong, undo everything."
- **Consistency** is about *rules*. It is partly the DB's job (constraints) and partly
  **yours** (correct transaction logic). The DB can't know "money is conserved" unless you
  code it.
- **Isolation** is about *concurrency*: "pretend I'm the only one here." It comes in
  **levels**, because full isolation costs performance.
- **Durability** is about *crashes*: "COMMIT means it's on disk."

> **Atomicity vs. Isolation, the most common confusion.** Atomicity says *what happens to my
> own transaction if it fails*. Isolation says *what other transactions can see while mine
> is running*. A system could be atomic but not isolated (others see your half-done
> transfer, but it does fully roll back on failure).

---

## Setup (one time)

Requires Docker Desktop (running). From **this folder**:

```bash
docker compose up -d
docker compose ps                       # wait until both are "running" (~20s for MySQL)
docker compose exec postgres psql -U learner -d acid_lab -f /scripts/00_setup.sql
```

Open an interactive Postgres shell any time with:

```bash
docker compose exec postgres psql -U learner -d acid_lab
```

Useful `psql` commands: `\dt` (list tables), `\d accounts` (describe), `\i /scripts/file.sql`
(run a file), `\q` (quit).

---

## Lessons (do them in order)

| # | File | Property | How |
| :-: | :--- | :--- | :--- |
| 0 | [postgres/00_setup.sql](postgres/00_setup.sql) | — | Creates the bank. **Re-run it to reset between labs.** |
| 1 | [postgres/01_atomicity.sql](postgres/01_atomicity.sql) | A | Script: success, mid-transaction failure, `ROLLBACK`, `SAVEPOINT` |
| 2 | [postgres/02_consistency.sql](postgres/02_consistency.sql) | C | Script: every constraint type rejecting bad data; deferred constraints |
| 3 | [postgres/03_isolation.md](postgres/03_isolation.md) | I | **Two terminals**: anomalies, isolation levels, `FOR UPDATE`, deadlocks, write skew |
| 4 | [postgres/04_durability.sql](postgres/04_durability.sql) | D | Script + crash test below |
| 5 | [mysql/README.md](mysql/README.md) | all | How MySQL differs, plus some gotchas that bite in production |

Run a script lesson:

```bash
docker compose exec postgres psql -U learner -d acid_lab -f /scripts/01_atomicity.sql
```

Read the script **before** running it and predict the output. Then run it and compare.

### The durability crash test (lesson 4)

```bash
# 1. Run lesson 4 so the table has committed rows
docker compose exec postgres psql -U learner -d acid_lab -f /scripts/04_durability.sql

# 2. Open a shell and leave a transaction UNcommitted
docker compose exec postgres psql -U learner -d acid_lab
#    acid_lab=# BEGIN;
#    acid_lab=*# INSERT INTO durability_test (note) VALUES ('never committed');
#    (leave this terminal open; do NOT type COMMIT)

# 3. In ANOTHER terminal, pull the plug. SIGKILL means no clean shutdown.
docker kill acid-postgres
docker compose up -d postgres

# 4. Check what survived
docker compose exec postgres psql -U learner -d acid_lab -c "SELECT * FROM durability_test;"
docker compose logs postgres | Select-String "redo|recovery"   # PowerShell
# docker compose logs postgres | grep -iE "redo|recovery"      # bash / macOS / Linux
```

You should see the committed rows survived, the uncommitted row is gone, and the logs show
Postgres **replaying the WAL** (`database system was not properly shut down; automatic
recovery in progress` ... `redo done`).

---

## Exercises

Try these yourself first. The answers are below.

1. Write a transaction that moves $75 from bob to carol **and** records it in `transfers`.
   Then try it with $750. What's in `transfers` afterwards?
2. In `psql`, run `UPDATE accounts SET balance = balance - 1 WHERE owner = 'alice';` with
   no `BEGIN`. Is that a transaction?
3. Add a rule so an account's balance can never exceed 10,000. Prove it works.
4. Two sessions both run `UPDATE accounts SET balance = balance + 10 WHERE owner='bob';`
   at the same time under READ COMMITTED. Is an update lost? Why is this different from Lab 4?
5. Your app transfers money by reading a balance, checking `balance >= amount` in Python,
   then updating. Name the anomaly risk and two ways to fix it.
6. Why might a logging service choose `synchronous_commit = off` while a payments service never would?
7. A teammate runs a MySQL migration: `START TRANSACTION; UPDATE ...; ALTER TABLE ...; <error>; ROLLBACK;`.
   What state is the database in?

<details>
<summary><b>Answers</b></summary>

1. ```sql
   BEGIN;
     UPDATE accounts SET balance = balance - 75 WHERE owner = 'bob';
     UPDATE accounts SET balance = balance + 75 WHERE owner = 'carol';
     INSERT INTO transfers (from_id, to_id, amount)
       SELECT f.id, t.id, 75 FROM accounts f, accounts t
       WHERE f.owner = 'bob' AND t.owner = 'carol';
   COMMIT;
   ```
   With $750, the first `UPDATE` violates `CHECK (balance >= 0)`, the transaction aborts,
   and **no** transfer row exists. That's atomicity.
2. Yes. With **autocommit** on (the default in both PG and MySQL), every standalone
   statement is its own implicit transaction.
3. `ALTER TABLE accounts ADD CONSTRAINT balance_cap CHECK (balance <= 10000);` and then
   `UPDATE accounts SET balance = 20000 WHERE owner='carol';` fails.
4. No update is lost. The final value is +20. `balance = balance + 10` is computed **by the
   database** while holding the row lock. The second session waits, then re-evaluates against
   the newly committed row. Lab 4 lost an update because the *application* computed the new
   value from a stale read.
5. A **lost update** (or overdraft race): two requests both see enough balance and both
   withdraw. Fixes: `SELECT ... FOR UPDATE` before checking; a single atomic statement
   `UPDATE accounts SET balance = balance - :amt WHERE id = :id AND balance >= :amt` (then
   check the rows affected); or SERIALIZABLE plus a retry loop. The `CHECK (balance >= 0)`
   constraint is also a last line of defense.
6. With it off, a crash can lose roughly the last fraction of a second of commits, but it
   never corrupts the data. Losing a few log lines is acceptable for much higher throughput.
   Losing a confirmed payment is not.
7. **Partially migrated.** The `ALTER TABLE` implicitly committed the `UPDATE` (and itself),
   so the `ROLLBACK` undid nothing before it. In PostgreSQL the whole thing would have rolled
   back cleanly.
</details>

---

## Key takeaways

- `COMMIT` = durable + atomic. Until then, nothing is real to anyone else.
- Put **business rules in constraints** wherever possible. The DB enforces them for every
  client, forever.
- The default isolation level is **not** fully serializable in either database. Read-then-write
  logic needs locking or a stronger level, **plus retries**.
- PostgreSQL and MySQL disagree on error handling inside transactions, transactional DDL, and
  default isolation. Know which one you're on.

**Next topic:** complex joins → `01-sql-relational/02-complex-joins/`

## Cleanup

```bash
docker compose down       # stop (keeps data)
docker compose down -v    # stop and delete all lab data
```
