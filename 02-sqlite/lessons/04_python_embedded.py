"""
04_python_embedded.py: calling SQLite from application code.

SQLite is a LIBRARY linked into your program, not a server. Python ships with it
(the `sqlite3` module), so there is nothing to install or start.

Run from the 02-sqlite folder:
    python lessons/04_python_embedded.py

Works on Python 3.8+ (no third-party packages).
"""
import sqlite3
import statistics
import sys
from contextlib import closing, contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out"
OUT.mkdir(exist_ok=True)
DB_PATH = OUT / "app.db"


def section(title):
    print(f"\n=== {title} ===")


def remove_db(path):
    """A database is a file, plus -wal/-shm (WAL mode) or -journal (rollback mode) side files."""
    for suffix in ("", "-wal", "-shm", "-journal"):
        p = Path(str(path) + suffix)
        if p.exists():
            p.unlink()


def open_db(path):
    """The connection setup you'd actually use in an application."""
    conn = sqlite3.connect(
        path,
        timeout=5.0,            # busy timeout: wait up to 5s for a lock instead of failing at once
        isolation_level=None,   # autocommit: WE write BEGIN/COMMIT (explicit beats implicit, see #6)
    )
    conn.row_factory = sqlite3.Row             # rows act like dicts: row["email"]
    conn.execute("PRAGMA journal_mode = WAL")  # readers don't block the writer (lesson 05)
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.execute("PRAGMA foreign_keys = ON")   # OFF by default, per connection!
    return conn


@contextmanager
def transaction(conn, mode="IMMEDIATE"):
    """BEGIN ... COMMIT, or ROLLBACK if anything raises. IMMEDIATE takes the write lock up front."""
    conn.execute(f"BEGIN {mode}")
    try:
        yield conn
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    else:
        conn.execute("COMMIT")


# --------------------------------------------------------------------------------------
section("1. Versions: the SQLite library is BUNDLED with your language runtime")
print(f"Python             : {sys.version.split()[0]}")
print(f"SQLite library     : {sqlite3.sqlite_version}   <- what features you get (STRICT 3.37, ->> 3.38, ...)")
print("Each runtime bundles its own copy: Python, Node, the sqlite3 CLI, and your phone's OS can all differ.")

# --------------------------------------------------------------------------------------
section("2. Opening a database = opening (or creating) a file")
remove_db(DB_PATH)
conn = open_db(DB_PATH)
conn.executescript("""
    CREATE TABLE users (
        id    INTEGER PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        name  TEXT NOT NULL
    ) STRICT;
    CREATE TABLE notes (
        id         INTEGER PRIMARY KEY,
        user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        body       TEXT    NOT NULL,
        created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    ) STRICT;
""")
print("Files on disk now:", sorted(p.name for p in OUT.glob("app.db*")))

with open(DB_PATH, "rb") as f:
    header = f.read(100)   # the first 100 bytes of page 1 are the database header
print(f"Header magic       : {header[:16]!r}")
print(f"Page size (bytes 16-17)  : {int.from_bytes(header[16:18], 'big')}"
      f"  == PRAGMA page_size {conn.execute('PRAGMA page_size').fetchone()[0]}")
print(f"Write/read version (18-19): {header[18]}/{header[19]}   (1 = rollback journal, 2 = WAL)")

# --------------------------------------------------------------------------------------
section("3. Parameter binding: ? (positional) and :name (named)")
cur = conn.execute("INSERT INTO users (email, name) VALUES (?, ?)", ("ada@example.com", "Ada"))
print(f"Inserted user id {cur.lastrowid}")
conn.execute("INSERT INTO users (email, name) VALUES (:email, :name)",
             {"email": "grace@example.com", "name": "Grace"})

new_users = [(f"user{i}@example.com", f"User {i}") for i in range(1, 6)]
with transaction(conn):
    cur = conn.executemany("INSERT INTO users (email, name) VALUES (?, ?)", new_users)
print(f"executemany inserted {cur.rowcount} rows in one transaction (one prepared statement, reused)")

# --------------------------------------------------------------------------------------
section("4. SQL injection: why you NEVER build SQL with f-strings")
evil = "nobody@example.com' OR '1'='1"
unsafe_sql = f"SELECT count(*) FROM users WHERE email = '{evil}'"
print(f"Unsafe query text  : {unsafe_sql}")
print(f"Unsafe result      : {conn.execute(unsafe_sql).fetchone()[0]} rows matched (every user leaked!)")
safe = conn.execute("SELECT count(*) FROM users WHERE email = ?", (evil,)).fetchone()[0]
print(f"Parameterized      : {safe} rows matched (the input is treated as a value, never as SQL)")
print("Note: parameters can't stand in for table/column names. Use an allowlist for those.")

# --------------------------------------------------------------------------------------
section("5. Reading rows")
row = conn.execute("SELECT id, email, name FROM users WHERE id = ?", (1,)).fetchone()
print(f"fetchone -> Row    : id={row['id']} email={row['email']} | as dict: {dict(row)}")
print("fetchall -> list   :", [r["name"] for r in conn.execute("SELECT name FROM users ORDER BY id LIMIT 3").fetchall()])
print("iterate (streams)  :", end=" ")
for r in conn.execute("SELECT name FROM users ORDER BY id DESC LIMIT 3"):
    print(r["name"], end=" | ")
print()

# --------------------------------------------------------------------------------------
section("6. Transactions in Python, including the classic 'forgot to commit' bug")
try:
    with transaction(conn):
        conn.execute("INSERT INTO notes (user_id, body) VALUES (1, 'first note')")
        conn.execute("INSERT INTO notes (user_id, body) VALUES (999, 'orphan')")  # FK violation
except sqlite3.IntegrityError as e:
    print(f"Rolled back both inserts: {e}")
print(f"Notes after failed transaction: {conn.execute('SELECT count(*) FROM notes').fetchone()[0]}")

# Python's DEFAULT mode (isolation_level="", deprecated in favor of `autocommit` in 3.12+)
# silently runs BEGIN before INSERT/UPDATE/DELETE and waits for you to call commit().
legacy = sqlite3.connect(DB_PATH)
legacy.execute("INSERT INTO notes (user_id, body) VALUES (1, 'never committed')")
print(f"Default-mode connection in_transaction after one INSERT: {legacy.in_transaction}")
legacy.close()   # closing without commit() = the INSERT is silently rolled back
lost = conn.execute("SELECT count(*) FROM notes WHERE body = 'never committed'").fetchone()[0]
print(f"Rows found after close() without commit(): {lost}   <- the bug")

legacy = sqlite3.connect(DB_PATH)
with legacy:   # `with conn:` COMMITS on success / ROLLS BACK on error, but does NOT close!
    legacy.execute("INSERT INTO notes (user_id, body) VALUES (1, 'committed via with')")
legacy.close()
print("With `with conn:` it's saved:",
      conn.execute("SELECT count(*) FROM notes WHERE body LIKE 'committed%'").fetchone()[0], "row")

# --------------------------------------------------------------------------------------
section("7. Your code runs INSIDE the database: custom SQL functions")
# Impossible with a client/server DB: SQLite calls straight back into this Python process.
def slugify(text):
    return "-".join("".join(c.lower() if c.isalnum() else " " for c in text).split())


class Median:
    def __init__(self):
        self.values = []

    def step(self, value):
        if value is not None:
            self.values.append(value)

    def finalize(self):
        return statistics.median(self.values) if self.values else None


conn.create_function("slugify", 1, slugify, deterministic=True)
conn.create_aggregate("median", 1, Median)
for r in conn.execute("SELECT name, slugify(name || ' profile page') AS slug FROM users LIMIT 2"):
    print(f"slugify            : {r['name']!r:10} -> {r['slug']}")
print("median(id)         :", conn.execute("SELECT median(id) FROM users").fetchone()[0])

conn.set_trace_callback(lambda sql: print(f"[trace] {sql}"))   # log every statement, handy for debugging
conn.execute("SELECT count(*) FROM users WHERE id > ?", (2,)).fetchone()
conn.set_trace_callback(None)

# --------------------------------------------------------------------------------------
section("8. Backups: the online backup API and a SQL dump")
backup_path = OUT / "app_backup.db"
remove_db(backup_path)
with closing(sqlite3.connect(backup_path)) as dest:
    conn.backup(dest, pages=1,
                progress=lambda status, remaining, total: print(f"  copied page {total - remaining}/{total}"))
print(f"Consistent copy written to {backup_path.name}, safe even while other connections write.")
print("First lines of conn.iterdump():")
for i, line in enumerate(conn.iterdump()):
    if i >= 4:
        break
    print("   ", " ".join(line.split())[:90])

# --------------------------------------------------------------------------------------
section("9. Cleanup")
conn.execute("PRAGMA optimize")   # refresh query planner statistics if useful; cheap
conn.close()                      # last connection closing checkpoints and removes -wal/-shm
print("Files after close():", sorted(p.name for p in OUT.glob("app.db*")))
print("Open it in the CLI:  sqlite3 out/app.db   then   .tables   SELECT * FROM users;")
