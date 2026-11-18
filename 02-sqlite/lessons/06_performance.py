"""
06_performance.py: the handful of things that decide whether SQLite is fast.

  1. Batch writes into transactions (by far the biggest win)
  2. Journal mode + synchronous setting (durability vs speed)
  3. Indexes, read with EXPLAIN QUERY PLAN
  4. ANALYZE / PRAGMA optimize
  5. VACUUM: deleted data doesn't shrink the file

Run from the 02-sqlite folder:
    python lessons/06_performance.py

The benchmark databases go in your OS temp folder, NOT in out/. Cloud-sync clients
(OneDrive, Dropbox, iCloud) watch and lock files, which skews timings and can
corrupt a database that's being written. Keep live databases out of synced folders.
Your numbers will differ by disk and OS; the RATIOS are the lesson.
"""
import os
import random
import sqlite3
import string
import tempfile
import time
from pathlib import Path

TMP = Path(tempfile.gettempdir()) / "sqlite_perf_lab"
TMP.mkdir(exist_ok=True)


def section(title):
    print(f"\n=== {title} ===")


def fresh(name, journal_mode="DELETE", synchronous="FULL"):
    path = TMP / name
    for suffix in ("", "-wal", "-shm", "-journal"):
        p = Path(str(path) + suffix)
        if p.exists():
            p.unlink()
    conn = sqlite3.connect(path, isolation_level=None)
    conn.execute(f"PRAGMA journal_mode = {journal_mode}")
    conn.execute(f"PRAGMA synchronous = {synchronous}")
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score INTEGER)")
    return conn, path


def row(i):
    return (f"name-{i}", i % 1000)


def plan(conn, sql, params=()):
    return " | ".join(r[3] for r in conn.execute("EXPLAIN QUERY PLAN " + sql, params))


def avg_ms(conn, sql, params, runs=20):
    t0 = time.perf_counter()
    for _ in range(runs):
        conn.execute(sql, params).fetchall()
    return (time.perf_counter() - t0) / runs * 1000


# ======================================================================================
section("1+2. Insert speed: transactions and durability settings")
print(f"  (benchmark files in {TMP})")
results = []

N_SLOW = 300   # one-transaction-per-row is slow, so fewer rows
conn, _ = fresh("a.db", "DELETE", "FULL")
t0 = time.perf_counter()
for i in range(N_SLOW):
    conn.execute("INSERT INTO t (name, score) VALUES (?, ?)", row(i))   # autocommit: 1 txn per row
results.append(("autocommit, rollback journal, sync=FULL", N_SLOW, time.perf_counter() - t0))
conn.close()

conn, _ = fresh("b.db", "WAL", "NORMAL")
t0 = time.perf_counter()
for i in range(N_SLOW):
    conn.execute("INSERT INTO t (name, score) VALUES (?, ?)", row(i))
results.append(("autocommit, WAL, sync=NORMAL", N_SLOW, time.perf_counter() - t0))
conn.close()

N_FAST = 100_000
conn, _ = fresh("c.db", "DELETE", "FULL")
t0 = time.perf_counter()
conn.execute("BEGIN")
for i in range(N_FAST):
    conn.execute("INSERT INTO t (name, score) VALUES (?, ?)", row(i))
conn.execute("COMMIT")
results.append(("ONE transaction, execute() in a loop", N_FAST, time.perf_counter() - t0))
conn.close()

conn, _ = fresh("d.db", "WAL", "NORMAL")
t0 = time.perf_counter()
conn.execute("BEGIN")
conn.executemany("INSERT INTO t (name, score) VALUES (?, ?)", (row(i) for i in range(N_FAST)))
conn.execute("COMMIT")
results.append(("ONE transaction, executemany, WAL", N_FAST, time.perf_counter() - t0))
conn.close()

baseline = results[0][1] / results[0][2]
print(f"  {'strategy':<42} {'rows':>8} {'seconds':>8} {'rows/sec':>11} {'speedup':>8}")
for label, n, secs in results:
    rate = n / secs
    print(f"  {label:<42} {n:>8,} {secs:>8.2f} {rate:>11,.0f} {rate / baseline:>7.0f}x")
print("  -> Every COMMIT must wait for the disk to confirm (fsync). Autocommit pays that per ROW;")
print("     a transaction pays it once per BATCH. WAL+NORMAL syncs less often, at the cost of")
print("     possibly losing the last few commits on power loss (never corrupting the file).")

# ======================================================================================
section("3. Indexes and EXPLAIN QUERY PLAN")
conn, path = fresh("idx.db")
conn.execute("DROP TABLE t")
conn.execute("""CREATE TABLE users (
    id INTEGER PRIMARY KEY, email TEXT, country TEXT, signup_day TEXT, score INTEGER)""")
countries = ["US", "DE", "IN", "BR", "JP", "NG", "FR", "MX"]
rand = random.Random(42)
conn.execute("BEGIN")
conn.executemany(
    "INSERT INTO users (email, country, signup_day, score) VALUES (?, ?, ?, ?)",
    ((f"{''.join(rand.choices(string.ascii_lowercase, k=8))}{i}@example.com",
      rand.choice(countries),
      f"2026-{rand.randint(1, 12):02d}-{rand.randint(1, 28):02d}",
      rand.randint(0, 10_000)) for i in range(200_000)))
conn.execute("COMMIT")
target = conn.execute("SELECT email FROM users WHERE id = 150000").fetchone()[0]
print("  200,000 users loaded.")

q1 = "SELECT id FROM users WHERE email = ?"
print(f"\n  Query: {q1}")
print(f"    no index : {avg_ms(conn, q1, (target,)):7.2f} ms   plan: {plan(conn, q1, (target,))}")
conn.execute("CREATE INDEX idx_users_email ON users (email)")
print(f"    indexed  : {avg_ms(conn, q1, (target,)):7.2f} ms   plan: {plan(conn, q1, (target,))}")

q2 = "SELECT signup_day, score FROM users WHERE country = ? ORDER BY signup_day DESC LIMIT 10"
print(f"\n  Query: {q2}")
print(f"    no index           : {avg_ms(conn, q2, ('DE',)):7.2f} ms   plan: {plan(conn, q2, ('DE',))}")
conn.execute("CREATE INDEX idx_users_country ON users (country)")
print(f"    (country)          : {avg_ms(conn, q2, ('DE',)):7.2f} ms   plan: {plan(conn, q2, ('DE',))}")
conn.execute("CREATE INDEX idx_users_country_day_score ON users (country, signup_day, score)")
print(f"    (country,day,score): {avg_ms(conn, q2, ('DE',)):7.2f} ms   plan: {plan(conn, q2, ('DE',))}")
print("""
  How to read a plan:
    SCAN users                       -> reads every row. Fine for tiny tables, bad for big ones.
    SEARCH users USING INDEX ...     -> jumps straight to matching rows via a B-tree.
    USE TEMP B-TREE FOR ORDER BY     -> had to sort the results itself. An index in that order avoids it.
    USING COVERING INDEX             -> the index holds every column needed; the table isn't touched.
  Column ORDER matters: (country, signup_day) serves "WHERE country=? ORDER BY signup_day",
  (signup_day, country) does not. Equality columns first, then range/sort columns.""")

# ======================================================================================
section("4. ANALYZE / PRAGMA optimize: give the planner statistics")
conn.execute("ANALYZE")
for tbl, idx, stat in conn.execute("SELECT tbl, idx, stat FROM sqlite_stat1 ORDER BY idx"):
    print(f"  sqlite_stat1  {idx or tbl:<30} {stat}")
print("  -> 'rows avg-rows-per-key ...': the planner uses this to choose between indexes.")
print("     In apps, run PRAGMA optimize periodically or before closing long-lived connections.")

# ======================================================================================
section("5. VACUUM: deleting rows does not shrink the file")


def file_stats(label):
    pages, free, size = (conn.execute("PRAGMA page_count").fetchone()[0],
                         conn.execute("PRAGMA freelist_count").fetchone()[0],
                         os.path.getsize(path))
    print(f"  {label:<26} file={size / 1e6:6.1f} MB  pages={pages:>6,}  free pages={free:>6,}")


file_stats("before delete:")
conn.execute("DELETE FROM users WHERE id > 100000")
file_stats("after deleting 50%:")
conn.execute("VACUUM")
file_stats("after VACUUM:")
print("  -> Emptied pages go on a FREELIST and get reused by future inserts, but the file never")
print("     shrinks on its own. (Scattered deletes are worse: they leave half-empty pages that")
print("     aren't even on the freelist.) VACUUM rebuilds the file compactly. It needs up to 2x")
print("     disk space and an exclusive lock while it runs. Alternatives: PRAGMA auto_vacuum =")
print("     INCREMENTAL (set before creating tables), or VACUUM INTO 'compact_copy.db'.")
conn.close()
