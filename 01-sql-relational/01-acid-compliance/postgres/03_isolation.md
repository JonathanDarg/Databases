# 03 Isolation (PostgreSQL): two-terminal walkthrough

**Isolation** means concurrent transactions don't step on each other. Ideally, running
transactions at the same time gives the same result as running them one after another.

You can't demo this with one script, because you need **two sessions open at the same
time**. Open two terminals in this folder and connect both:

```bash
docker compose exec postgres psql -U learner -d acid_lab
```

Call them **A** and **B**. Run `\i /scripts/00_setup.sql` in A first to reset the data.
Run each step in the order shown, switching terminals as labeled.

---

## The anomalies isolation protects against

| Anomaly | What goes wrong |
| :--- | :--- |
| **Dirty read** | You read another transaction's *uncommitted* change, which may later be rolled back. |
| **Non-repeatable read** | You read a row twice in one transaction and get different values, because someone committed in between. |
| **Phantom read** | You run the same `WHERE` query twice and new rows appear or disappear. |
| **Lost update** | Two transactions read, compute, and write the same row, and one write silently overwrites the other. |
| **Write skew** | Two transactions each check a rule, each write a *different* row, and together they break the rule. |

## SQL isolation levels vs. what PostgreSQL actually does

| Level | Dirty read | Non-repeatable | Phantom | Notes |
| :--- | :---: | :---: | :---: | :--- |
| READ UNCOMMITTED | never in PG | possible | possible | PG treats it as READ COMMITTED |
| **READ COMMITTED** (PG default) | no | possible | possible | Each *statement* sees a fresh snapshot |
| REPEATABLE READ | no | no | no in PG | Whole *transaction* sees one snapshot |
| SERIALIZABLE | no | no | no | Also blocks write skew; may abort you with a serialization error |

PostgreSQL implements this with **MVCC** (Multi-Version Concurrency Control). Writers
create new row *versions* instead of overwriting, so readers never block writers and
writers never block readers. Each transaction just picks which versions it can see.

---

## Lab 1: No dirty reads

| Step | Session | Run |
| :-: | :-: | :--- |
| 1 | A | `BEGIN;` |
| 2 | A | `UPDATE accounts SET balance = 0 WHERE owner = 'alice';` |
| 3 | B | `SELECT balance FROM accounts WHERE owner = 'alice';` (still **500**, A hasn't committed) |
| 4 | A | `ROLLBACK;` |

B never saw the 0. Even `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED` in B won't
show it, because PostgreSQL never allows dirty reads.

## Lab 2: Non-repeatable read under READ COMMITTED

| Step | Session | Run |
| :-: | :-: | :--- |
| 1 | A | `BEGIN;` (default READ COMMITTED) |
| 2 | A | `SELECT balance FROM accounts WHERE owner = 'alice';` → 500 |
| 3 | B | `UPDATE accounts SET balance = 400 WHERE owner = 'alice';` (autocommits) |
| 4 | A | `SELECT balance FROM accounts WHERE owner = 'alice';` → **400**, which changed mid-transaction! |
| 5 | A | `COMMIT;` |

## Lab 3: The same thing under REPEATABLE READ

Reset first: `\i /scripts/00_setup.sql`

| Step | Session | Run |
| :-: | :-: | :--- |
| 1 | A | `BEGIN ISOLATION LEVEL REPEATABLE READ;` |
| 2 | A | `SELECT balance FROM accounts WHERE owner = 'alice';` → 500 |
| 3 | B | `UPDATE accounts SET balance = 400 WHERE owner = 'alice';` |
| 4 | A | `SELECT balance FROM accounts WHERE owner = 'alice';` → still **500** (frozen snapshot) |
| 5 | A | `UPDATE accounts SET balance = balance - 1 WHERE owner = 'alice';` → **ERROR: could not serialize access due to concurrent update** |
| 6 | A | `ROLLBACK;` |

Step 5 matters: A's snapshot is out of date, so PostgreSQL refuses to let A write on top
of a value it never saw. **Your application must catch this error and retry the
transaction.** That's the price of stronger isolation.

## Lab 4: Lost update, and how to prevent it

Reset first. This simulates application code that reads, computes in the app, and then writes.

**The bug (READ COMMITTED, no locking):**

| Step | Session | Run |
| :-: | :-: | :--- |
| 1 | A | `BEGIN;` `SELECT balance FROM accounts WHERE owner='bob';` → 100 (app plans to add 10 → 110) |
| 2 | B | `BEGIN;` `SELECT balance FROM accounts WHERE owner='bob';` → 100 (app plans to add 20 → 120) |
| 3 | A | `UPDATE accounts SET balance = 110 WHERE owner='bob';` `COMMIT;` |
| 4 | B | `UPDATE accounts SET balance = 120 WHERE owner='bob';` `COMMIT;` |
| 5 | A | `SELECT balance FROM accounts WHERE owner='bob';` → **120**. A's +10 was **lost**. |

**Fix 1: let the database do the math (atomic update):**
`UPDATE accounts SET balance = balance + 10 WHERE owner='bob';` Row-level locking makes
the second writer wait and then re-read the committed value.

**Fix 2: pessimistic locking with `SELECT ... FOR UPDATE`:**

| Step | Session | Run |
| :-: | :-: | :--- |
| 1 | A | `BEGIN;` `SELECT balance FROM accounts WHERE owner='bob' FOR UPDATE;` → 100 |
| 2 | B | `BEGIN;` `SELECT balance FROM accounts WHERE owner='bob' FOR UPDATE;` → **hangs** (waiting on A's lock) |
| 3 | A | `UPDATE accounts SET balance = 110 WHERE owner='bob';` `COMMIT;` |
| 4 | B | unblocks and sees **110**. `UPDATE accounts SET balance = 130 WHERE owner='bob';` `COMMIT;` |

Final: 130. Both updates survived.

## Lab 5: Deadlock (the DB detects it for you)

Reset first.

| Step | Session | Run |
| :-: | :-: | :--- |
| 1 | A | `BEGIN;` `UPDATE accounts SET balance = balance - 1 WHERE owner='alice';` |
| 2 | B | `BEGIN;` `UPDATE accounts SET balance = balance - 1 WHERE owner='bob';` |
| 3 | A | `UPDATE accounts SET balance = balance + 1 WHERE owner='bob';` → waits for B |
| 4 | B | `UPDATE accounts SET balance = balance + 1 WHERE owner='alice';` → **ERROR: deadlock detected** |
| 5 | A | unblocks. `COMMIT;` |
| 6 | B | `ROLLBACK;` |

After about 1 second (`deadlock_timeout`), PostgreSQL picks a victim and aborts it.
**Prevention:** always lock rows in a consistent order, for example by ascending `id`.

## Lab 6: Write skew, which only SERIALIZABLE stops

Rule: *at least one account must keep a balance above 0.* Nothing in the schema enforces
this, so it is an application-level rule. Reset first. Alice (500) and bob (100) are
above 0, and carol is already at 0.

| Step | Session | Run |
| :-: | :-: | :--- |
| 1 | A | `BEGIN ISOLATION LEVEL REPEATABLE READ;` `SELECT count(*) FROM accounts WHERE balance > 0;` → 2, "safe to empty alice" |
| 2 | B | `BEGIN ISOLATION LEVEL REPEATABLE READ;` `SELECT count(*) FROM accounts WHERE balance > 0;` → 2, "safe to empty bob" |
| 3 | A | `UPDATE accounts SET balance = 0 WHERE owner='alice';` `COMMIT;` |
| 4 | B | `UPDATE accounts SET balance = 0 WHERE owner='bob';` `COMMIT;` → succeeds |
| 5 | A | `SELECT count(*) FROM accounts WHERE balance > 0;` → **0**. The rule is broken. |

Now repeat it with `BEGIN ISOLATION LEVEL SERIALIZABLE;` in both sessions. Step 4 fails with
**ERROR: could not serialize access due to read/write dependencies among transactions**.
Retry B and it will see count = 1 and refuse to empty bob.

---

## Takeaways

- READ COMMITTED (the PG default) is fine for most single-statement work, but
  **read-then-write logic needs `FOR UPDATE`, an atomic `UPDATE`, or a higher level.**
- REPEATABLE READ and SERIALIZABLE trade throughput for safety, and **require retry loops**
  in your app for SQLSTATE `40001` (serialization failure) and `40P01` (deadlock).
- See [../mysql/README.md](../mysql/README.md) for how MySQL/InnoDB differs: its default is
  REPEATABLE READ, and it uses gap locks instead of aborting.
