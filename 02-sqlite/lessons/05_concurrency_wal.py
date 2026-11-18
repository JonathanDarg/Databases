"""
05_concurrency_wal.py: locking, journal modes, and the "database is locked" error.

SQLite allows MANY readers but only ONE writer at a time, per database file. How
readers and that writer interact depends on the journal mode. This lesson opens
several connections to one file and makes them collide on purpose.

Run from the 02-sqlite folder:
    python lessons/05_concurrency_wal.py

Each connection below stands in for a separate process or thread in a real app.
"""
import sqlite3
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out"
OUT.mkdir(exist_ok=True)
DB = OUT / "concurrency.db"


def section(title):
    print(f"\n=== {title} ===")


def connect(timeout=0.0):
    # isolation_level=None -> no hidden BEGINs from Python; we control transactions exactly.
    # timeout = SQLite's busy timeout: how long to retry a lock before raising "database is locked".
    return sqlite3.connect(DB, timeout=timeout, isolation_level=None, check_same_thread=False)


def fresh_db(journal_mode):
    for suffix in ("", "-wal", "-shm", "-journal"):
        p = Path(str(DB) + suffix)
        if p.exists():
            p.unlink()
    c = connect()
    mode = c.execute(f"PRAGMA journal_mode = {journal_mode}").fetchone()[0]
    c.execute("CREATE TABLE counter (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)")
    c.execute("INSERT INTO counter VALUES (1, 0)")
    c.close()
    return mode


def read_n(conn):
    return conn.execute("SELECT n FROM counter WHERE id = 1").fetchone()[0]


def attempt(label, fn):
    """Run fn, report success/failure and how long it took."""
    t0 = time.perf_counter()
    try:
        fn()
        print(f"  {label:<44} OK      ({time.perf_counter() - t0:.2f}s)")
        return True
    except sqlite3.OperationalError as e:
        print(f"  {label:<44} FAILED  ({time.perf_counter() - t0:.2f}s): {e}")
        return False


# ======================================================================================
section("1. Rollback-journal mode (DELETE): an open reader blocks the writer's COMMIT")
print("  journal_mode =", fresh_db("DELETE"))
reader, writer = connect(), connect(timeout=0.5)

reader.execute("BEGIN")
print(f"  reader: BEGIN; reads n = {read_n(reader)}   (now holds a SHARED lock)")
attempt("writer: BEGIN IMMEDIATE (RESERVED lock)", lambda: writer.execute("BEGIN IMMEDIATE"))
attempt("writer: UPDATE (change sits in its cache)", lambda: writer.execute("UPDATE counter SET n = n + 1"))
attempt("writer: COMMIT (needs EXCLUSIVE lock)", lambda: writer.execute("COMMIT"))
print("  -> To commit, rollback mode must overwrite pages in the main file, so it waits for")
print("     every reader to leave. It gave up after its 0.5s busy timeout.")
reader.execute("COMMIT")
attempt("writer: COMMIT again after reader finished", lambda: writer.execute("COMMIT"))
reader.close(); writer.close()

# ======================================================================================
section("2. WAL mode: readers and the writer don't block each other")
print("  journal_mode =", fresh_db("WAL"))
reader, writer = connect(), connect(timeout=0.5)

reader.execute("BEGIN")
print(f"  reader: BEGIN; reads n = {read_n(reader)}   (pins a SNAPSHOT of the database)")
attempt("writer: BEGIN IMMEDIATE + UPDATE + COMMIT",
        lambda: writer.executescript("BEGIN IMMEDIATE; UPDATE counter SET n = n + 1; COMMIT;"))
print(f"  reader: still inside its transaction, reads n = {read_n(reader)}   (consistent snapshot)")
reader.execute("COMMIT")
print(f"  reader: after its transaction ends, reads n = {read_n(reader)}")
print("  -> The writer appended to the -wal file; the reader kept reading the old pages.")
reader.close(); writer.close()

# ======================================================================================
section("3. Two writers: one waits (busy_timeout) or fails ('database is locked')")
fresh_db("WAL")
a, b = connect(), connect(timeout=0.5)
a.execute("BEGIN IMMEDIATE")
print("  A: BEGIN IMMEDIATE   (A owns the single write lock)")
attempt("B: BEGIN IMMEDIATE with 0.5s timeout", lambda: b.execute("BEGIN IMMEDIATE"))
a.execute("ROLLBACK")

a, b = connect(), connect(timeout=5.0)
a.execute("BEGIN IMMEDIATE")
print("  A: BEGIN IMMEDIATE again; a background thread will COMMIT it after 1 second")
threading.Timer(1.0, lambda: a.execute("COMMIT")).start()
attempt("B: BEGIN IMMEDIATE with 5s timeout", lambda: b.execute("BEGIN IMMEDIATE"))
b.execute("COMMIT")
print("  -> With a busy timeout, B simply WAITED ~1s for A. Always set one (Python's default is 5s).")
a.close(); b.close()

# ======================================================================================
section("4. The DEFERRED-transaction trap: read first, then write = instant failure")
fresh_db("WAL")
a, b = connect(timeout=5.0), connect(timeout=5.0)
a.execute("BEGIN")   # plain BEGIN = DEFERRED: takes no lock until the first read/write
print(f"  A: BEGIN (deferred); reads n = {read_n(a)}")
b.execute("UPDATE counter SET n = n + 10")
print("  B: UPDATE ... (autocommit) -> committed, n is now 10")
attempt("A: UPDATE based on its stale snapshot", lambda: a.execute("UPDATE counter SET n = n + 1"))
print("  -> Fails IMMEDIATELY despite the 5s timeout: waiting can't help, because A's")
print("     snapshot is out of date (SQLITE_BUSY_SNAPSHOT). The app must ROLLBACK and retry.")
a.execute("ROLLBACK")

print("  Fix: start read-then-write transactions with BEGIN IMMEDIATE:")
a.execute("BEGIN IMMEDIATE")
print(f"  A: BEGIN IMMEDIATE; reads n = {read_n(a)}")
t = threading.Thread(target=lambda: attempt("B: UPDATE (waits for A)", lambda: b.execute("UPDATE counter SET n = n + 10")))
t.start()
time.sleep(0.5)
a.execute("UPDATE counter SET n = n + 1")
a.execute("COMMIT")
print("  A: UPDATE + COMMIT")
t.join()
print(f"  Final n = {read_n(a)}  (10 + 1 + 10: no lost updates, nobody failed)")
a.close(); b.close()

# ======================================================================================
section("5. What WAL looks like on disk, and checkpoints")
fresh_db("WAL")
c = connect()
c.execute("CREATE TABLE blobs (id INTEGER PRIMARY KEY, data BLOB)")
c.execute("BEGIN")
c.executemany("INSERT INTO blobs (data) VALUES (randomblob(500))", [()] * 3000)
c.execute("COMMIT")


def sizes(label):
    s = {sfx or "db": (Path(str(DB) + sfx).stat().st_size if Path(str(DB) + sfx).exists() else 0)
         for sfx in ("", "-wal", "-shm")}
    print(f"  {label:<36} db={s['db']:>9,}  -wal={s['-wal']:>9,}  -shm={s['-shm']:>7,} bytes")


sizes("after inserting ~1.5 MB:")
print("  -> New pages went to the -wal file. The main .db file hasn't been touched yet.")
busy, log_frames, checkpointed = c.execute("PRAGMA wal_checkpoint(FULL)").fetchone()
sizes("after wal_checkpoint(FULL):")
print(f"  -> Checkpoint copied {checkpointed} of {log_frames} WAL frames (pages) into the .db file.")
print("     The WAL file keeps its size so it can be reused; TRUNCATE also shrinks it to 0:")
c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
sizes("after wal_checkpoint(TRUNCATE):")
print("  -> SQLite checkpoints automatically once the WAL passes ~1000 pages (wal_autocheckpoint)")
print("     and when the last connection closes. You rarely need to call it yourself.")
print("  -> The -shm file is a shared-memory index of the WAL. Every process must be on the SAME")
print("     machine to share it, which is why WAL (and SQLite generally) must not run on network drives.")
c.close()
sizes("after the last connection closed:")
