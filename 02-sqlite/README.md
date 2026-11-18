# 02 · SQLite: Embedded / Local SQL

> **Goal:** understand what SQLite actually is and how it works inside. Learn when it's the
> right tool (more often than people think) and when it isn't, and be able to set it up,
> call it, tune it, and operate it like a professional.

**Quick start** (from this folder, after [installing the CLI](#4-setup)):

```bash
sqlite3 out/library.db ".read lessons/01_cli_tour.sql"
python lessons/04_python_embedded.py
```

## Contents

1. [What SQLite is (and isn't)](#1-what-sqlite-is-and-isnt)
2. [Why it's used, and when not to use it](#2-why-its-used-and-when-not-to-use-it)
3. [How it works inside](#3-how-it-works-inside)
4. [Setup](#4-setup)
5. [Calling SQLite: CLI, Python, Node, and every other language](#5-calling-sqlite)
6. [Production configuration](#6-production-configuration)
7. [Schema design the SQLite way](#7-schema-design-the-sqlite-way)
8. [Performance](#8-performance)
9. [Modern SQL features and versions](#9-modern-sql-features-and-which-version-you-need)
10. [Operations: backups, migrations, replication, corruption](#10-operations)
11. [Security](#11-security)
12. [Testing with SQLite](#12-testing-with-sqlite)
13. [Limits](#13-limits)
14. [SQLite vs PostgreSQL vs MySQL](#14-sqlite-vs-postgresql-vs-mysql)
15. [Gotchas cheat sheet](#15-gotchas-cheat-sheet)
16. [Lessons](#16-lessons) · [Exercises](#17-exercises) · [Further reading](#18-further-reading)

---

## 1. What SQLite is (and isn't)

SQLite is a **C library** that implements a complete SQL database engine. It reads and writes
an ordinary file on disk. There is **no server process**, **no configuration**, **no users or
passwords**, and **no network protocol**. Your program calls functions in the library, and
the library reads and writes the file.

```
 Client/server (PostgreSQL, MySQL)            Embedded (SQLite)
 ┌──────────┐   TCP    ┌───────────────┐      ┌───────────────────────────┐
 │ your app │ ───────▶ │ database      │      │ your app                  │
 └──────────┘ network  │ server process│      │   └─ SQLite library ──────┼──▶ app.db
                       └──────┬────────┘      └───────────────────────────┘   (one file)
                              ▼                 a function call, not a
                        data directory          network round-trip
```

Key facts:

| | |
| :--- | :--- |
| **Serverless** | Nothing to install, start, monitor, or keep alive. The library runs inside your process. |
| **Zero-config** | Opening a file path *is* the setup. If the file doesn't exist, it's created. |
| **Single file** | The whole database (tables, indexes, schema) lives in one cross-platform file. Copy it to a Mac, a Linux server, or a phone and it just works. |
| **Small** | Under 1 MB of compiled code. |
| **Full SQL + ACID** | Transactions, joins, CTEs, window functions, triggers, views, JSON, full-text search. |
| **Stable file format** | Backwards-compatible since 2004, with support pledged through 2050. The US Library of Congress lists it as a recommended format for preserving datasets. |
| **Heavily tested** | 100% branch test coverage, with hundreds of times more test code than library code. |
| **Public domain** | No license at all. Use it anywhere, including commercially. |

It is the **most widely deployed database engine in the world**. It ships in every Android and
iOS device, every major web browser, macOS and Windows, Python's standard library, and countless
desktop apps. sqlite.org estimates over a *trillion* SQLite databases are in active use.

> **The mental shift:** don't think of SQLite as a small PostgreSQL. Think of it as a
> replacement for `fopen()`. It's a better way for a program to store its own data than
> inventing a file format, with SQL and transactions included.

---

## 2. Why it's used, and when not to use it

### Where SQLite is the right choice

| Use case | Why it fits |
| :--- | :--- |
| **Mobile and desktop apps** | Local data storage on every device. Android (Room), iOS (Core Data/SwiftData use it underneath), Electron apps. |
| **Application file format** | Instead of a custom binary or XML format, your "document" *is* a SQLite DB: atomic saves, partial reads, queryable. |
| **Embedded devices and IoT** | Tiny, no administration, survives power loss. |
| **Websites and APIs on one server** | Easily handles low-to-medium traffic sites (sqlite.org itself serves hundreds of thousands of requests/day on SQLite). Rails 8 defaults to SQLite in production. |
| **Data analysis** | Import a CSV and run SQL on it in seconds (lesson 01). |
| **Caches and local state** | CLI tools, build systems, and browsers (history and cookies are SQLite). |
| **Testing and prototyping** | `:memory:` databases are created in microseconds. |
| **Edge and local-first apps** | Cloudflare D1, Turso/libSQL, and in-browser SQLite (WASM) put data next to the user. |
| **Data interchange** | Ship a dataset as one `.db` file instead of a pile of CSVs with lost types. |

### Where it's the wrong choice

| Situation | Why | Use instead |
| :--- | :--- | :--- |
| **Many machines writing** (multiple app servers behind a load balancer) | It's a local file. There's no network protocol, and network filesystems break its locking. | PostgreSQL, MySQL (or a distributed SQLite: rqlite, LiteFS, Turso) |
| **High write concurrency** (thousands of concurrent writing transactions) | **One writer at a time** per database file. Writes are fast, but they're serialized. | PostgreSQL / MySQL |
| **Need users, roles, and GRANTs** | No user accounts. Whoever can read the file can read all of it. | Client/server DB |
| **The DB must live on a different machine than the app** | That's literally client/server. | Client/server DB |
| **Heavy analytics on huge data** (column scans over billions of rows) | Row-oriented storage. | DuckDB (embedded, *columnar*: "SQLite for analytics"), ClickHouse |

> Rule of thumb from sqlite.org: *"SQLite does not compete with client/server databases.
> SQLite competes with `fopen()`."* If the data is local to one machine, SQLite is probably
> fine. If many machines need to share it over a network, use a server.

---

## 3. How it works inside

### 3.1 Architecture

Every SQL statement goes through this pipeline, entirely inside your process:

```
  your code:  conn.execute("SELECT name FROM users WHERE id = ?", (42,))
       │
  ┌────▼───────────────────────────────────────────────────────────────────┐
  │ Interface      sqlite3_prepare_v2 / bind / step / column / finalize    │
  │ Tokenizer ──▶ Parser ──▶ Code generator + query planner                │  "compiler"
  │ Virtual machine (VDBE): executes the compiled BYTECODE program         │
  │ B-tree layer: every table and index is a B-tree of fixed-size pages    │  "storage
  │ Pager: page cache, transactions, rollback journal / WAL, file locking  │   engine"
  │ VFS (OS interface): open, read, write, lock, fsync on Windows/Unix/... │
  └────┬───────────────────────────────────────────────────────────────────┘
       ▼
    app.db  (+ app.db-wal and app.db-shm in WAL mode, or app.db-journal during a rollback-mode write)
```

- **Prepared statements are compiled programs.** `EXPLAIN SELECT ...` shows the bytecode;
  `EXPLAIN QUERY PLAN SELECT ...` shows the planner's strategy. Reusing a prepared statement
  skips parsing and planning, which is why drivers cache them and why bound parameters (same
  SQL text, different values) beat building a new SQL string for each row.
- **The VFS is pluggable.** That's how SQLite runs in browsers (WASM + OPFS) and how
  encryption extensions work.
- **No network means many small queries are cheap.** The "N+1 query problem" that hurts
  client/server apps is mostly harmless here, because each query is a function call
  (microseconds), not a network round-trip.

### 3.2 The file format

- The file is an array of **pages** (default **4096 bytes**). Page 1 starts with a
  100-byte **header** beginning with the magic string `SQLite format 3\0`. Lesson 04 reads it
  with raw Python file I/O.
- Every table and every index is a separate **B-tree**:
  - A **table B-tree** is keyed by the 64-bit **rowid**; rows live in the leaf pages.
  - An **index B-tree** is keyed by `(indexed columns..., rowid)`. An index lookup finds the
    rowid, then does a second lookup in the table B-tree. A **covering index** contains every
    column the query needs, which skips that second lookup (lesson 06).
  - A `WITHOUT ROWID` table is keyed directly by its PRIMARY KEY (good for composite or text keys).
- The schema itself is stored in a table called **`sqlite_schema`** (formerly `sqlite_master`)
  as the original `CREATE` statements.
- Each row is stored as a **record**: a header listing each value's type and size, then the
  values. **Every value carries its own type**, which is why SQLite's typing is dynamic (§3.5).
- Deleted data frees pages onto a **freelist** for reuse. The file doesn't shrink until you
  `VACUUM`.

### 3.3 Transactions and journaling: how a COMMIT survives a crash

SQLite has two ways to make commits atomic and durable.

**Rollback journal** (the default, `journal_mode=DELETE`): *save the old pages, then overwrite in place*

```
1. Read: take a SHARED lock, read pages.
2. Start writing: take a RESERVED lock (only one connection can hold it). Changes go to memory.
3. Copy the ORIGINAL pages into app.db-journal and fsync it.
4. Take PENDING, then EXCLUSIVE: wait for all readers to finish.
5. Write the changed pages into app.db and fsync.
6. Delete the journal file.   <-- THIS is the commit point
```
If the process crashes before step 6, the next connection finds a **hot journal** and copies
the original pages back. Result: all or nothing.

**Write-ahead log** (`journal_mode=WAL`, recommended): *append new pages, merge them in later*

```
1. A writer APPENDS changed pages to app.db-wal, then a commit record. fsync (depending on `synchronous`).
2. Readers check the WAL index (app.db-shm) for the newest version of each page up to
   their snapshot, and otherwise read app.db.
3. A CHECKPOINT copies WAL pages back into app.db (automatic every ~1000 pages and on last close).
```

| | Rollback journal | WAL |
| :--- | :--- | :--- |
| Readers block the writer? | **Yes**, at commit time | **No** |
| Writer blocks readers? | Yes, briefly during commit | **No**. Readers see a snapshot. |
| Writers at once | 1 | 1 |
| Write speed | Slower (several fsyncs + journal file churn) | Faster (sequential appends) |
| Files | `app.db` (+ `-journal` during writes) | `app.db`, `app.db-wal`, `app.db-shm` |
| Network filesystem | Discouraged | **Not supported** (needs shared memory) |
| Setting persists? | n/a | **Yes**, stored in the file |

Lesson 05 shows each row of this table happening.

### 3.4 Locking, concurrency, and isolation

- **Many readers, one writer**, per database file, enforced with OS file locks.
- When a lock isn't available, SQLite returns **`SQLITE_BUSY`** ("database is locked").
  A **busy timeout** makes it retry for up to N ms first. Without one, you fail instantly.
- Transaction types:
  - `BEGIN` / `BEGIN DEFERRED` (default) takes no lock until first use. **Trap:** a transaction
    that reads and *then* writes can fail instantly with `SQLITE_BUSY`, timeout or not, if
    someone else wrote in between (lesson 05, section 4).
  - `BEGIN IMMEDIATE` takes the write lock right away. **Use this for any transaction that
    will write.**
  - `BEGIN EXCLUSIVE` is like IMMEDIATE, and in rollback mode it also blocks readers.
- **Isolation is SERIALIZABLE.** Because there's only one writer, transactions can't interleave
  writes. In WAL mode, each read transaction sees a consistent snapshot. Compare that with
  lesson 01's isolation levels: SQLite simply doesn't have the anomalies.
- **ACID in SQLite:** **A** comes from the journal/WAL. **C** comes from constraints, *but*
  foreign keys are off by default and types aren't enforced unless the table is `STRICT`.
  **I** is serializable. **D** comes from fsync, controlled by `PRAGMA synchronous`.

### 3.5 The type system: dynamic typing and type affinity

This is the biggest difference from other SQL databases.

- A **value** has one of 5 **storage classes**: `NULL`, `INTEGER` (1 to 8 bytes, variable),
  `REAL` (8-byte float), `TEXT` (UTF-8/16), `BLOB` (raw bytes).
- A **column** has a **type affinity**, which is only a *preference*. SQLite converts a value
  when it can do so losslessly and otherwise stores it as-is. You can put `'hello'` in an
  `INTEGER` column.
- Affinity comes from **substring rules** on the declared type name, checked in this order:

  | Declared type contains | Affinity | Surprising consequence |
  | :--- | :--- | :--- |
  | `INT` | INTEGER | `FLOATING POINT` → INTEGER (contains "INT") |
  | `CHAR`, `CLOB`, `TEXT` | TEXT | `VARCHAR(3)` doesn't limit length |
  | `BLOB`, or no type | BLOB | stores exactly what you give it |
  | `REAL`, `FLOA`, `DOUB` | REAL | |
  | anything else | NUMERIC | `STRING` → NUMERIC, so `'007'` becomes `7`. `DECIMAL` is just a float. |

- There are **no** `BOOLEAN`, `DATE`, `DATETIME`, `DECIMAL`, or `UUID` types. Use INTEGER 0/1
  for booleans, ISO-8601 TEXT or Unix-epoch INTEGER for times, INTEGER cents for money, and
  TEXT or BLOB for UUIDs.
- **`STRICT` tables** (3.37+) turn on real type enforcement: only `INT`, `INTEGER`, `REAL`,
  `TEXT`, `BLOB`, `ANY` are allowed, and mismatches raise errors. **Use STRICT for new tables.**

Lesson 02 demonstrates every rule above.

---

## 4. Setup

### 4.1 The `sqlite3` command-line shell

| OS | Install | Notes |
| :--- | :--- | :--- |
| **Windows** | `winget install SQLite.SQLite` | Then **open a new terminal** so `sqlite3` is on PATH |
| macOS | Preinstalled (often old). `brew install sqlite` for current | Homebrew's is keg-only; follow its PATH hint |
| Ubuntu/Debian | `sudo apt install sqlite3` | Distro versions lag behind |
| Any | Download "sqlite-tools" from [sqlite.org/download.html](https://sqlite.org/download.html) | Also includes `sqldiff`, `sqlite3_analyzer`, `sqlite3_rsync` |

```bash
sqlite3 --version     # check it worked
```

**Make the CLI pleasant.** It runs `~/.sqliterc` (Windows: `%USERPROFILE%\.sqliterc`) at startup:

```
.headers on
.mode box
.timer on
PRAGMA foreign_keys = ON;
```

### 4.2 The SQLite version comes from your runtime

There is no "SQLite server version". **Each program bundles its own copy of the library.** On
this machine, at the time of writing:

| Runtime | SQLite version | Check with |
| :--- | :--- | :--- |
| sqlite3 CLI (current winget package) | 3.54.x | `sqlite3 --version` |
| Node 22.14 | 3.47.2 | `SELECT sqlite_version()` |
| Python 3.9 | **3.37.2** (no `->>`, no `unixepoch()`) | `python -c "import sqlite3; print(sqlite3.sqlite_version)"` |

Same file, different features depending on who opens it. **Always check `sqlite_version()` in
the runtime you deploy**, and upgrade the runtime (or use a driver that bundles a newer SQLite)
if you need newer syntax.

### 4.3 GUI tools

- **DB Browser for SQLite** (free, all OSes): browse, edit, and run SQL.
- **DBeaver**, **SQLiteStudio**, **TablePlus**, **DataGrip**: general database GUIs.
- **VS Code**: search the marketplace for a "SQLite Viewer" extension to open `.db` files directly.
- **Datasette**: instantly turns a `.db` file into a browsable website and JSON API.
- **sqlite-utils**: a CLI and Python library for bulk-loading JSON/CSV and transforming tables.

---

## 5. Calling SQLite

### 5.1 The C API underneath every driver

Every language binding wraps the same few calls. Knowing them explains driver behavior:

```c
sqlite3 *db;  sqlite3_stmt *stmt;
sqlite3_open_v2("app.db", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
sqlite3_busy_timeout(db, 5000);
sqlite3_prepare_v2(db, "SELECT name FROM users WHERE id = ?", -1, &stmt, NULL); // compile
sqlite3_bind_int(stmt, 1, 42);                                                   // bind
while (sqlite3_step(stmt) == SQLITE_ROW)                                         // run, one row per step
    printf("%s\n", sqlite3_column_text(stmt, 0));
sqlite3_finalize(stmt);                                                          // free
sqlite3_close(db);
```
To embed it in a C/C++ program, add the single-file **amalgamation** (`sqlite3.c` + `sqlite3.h`)
to your build.

### 5.2 The CLI

```bash
sqlite3 app.db                                # interactive shell (creates app.db if missing)
sqlite3 app.db "SELECT count(*) FROM users;"  # one-shot query
sqlite3 app.db ".read script.sql"             # run a file (works in PowerShell, unlike `<`)
sqlite3 -readonly app.db                      # can't modify anything
sqlite3 -json app.db "SELECT * FROM users"    # also -csv, -box, -markdown, -line, -table
sqlite3 :memory:                              # throwaway in-memory database
```

| Dot command | What it does |
| :--- | :--- |
| `.help` / `.quit` | help / exit |
| `.open FILE` | switch to another database file |
| `.tables`, `.schema [TABLE]`, `.indexes` | inspect the schema |
| `.headers on`, `.mode box\|table\|csv\|json\|markdown\|line\|insert` | output formatting |
| `.import --csv FILE TABLE` | load CSV (creates TEXT columns if the table doesn't exist) |
| `.once FILE` / `.output FILE` | send the next query's / all output to a file |
| `.excel` | open the next query's result in your spreadsheet app |
| `.read FILE` | run SQL from a file |
| `.dump [TABLE]` | export as SQL text |
| `.backup FILE` / `.restore FILE` | safe online backup / restore |
| `.timer on`, `.eqp on`, `.changes on` | show timing / query plans / rows changed |
| `.expert` | suggest indexes for the next query |
| `.lint fkey-indexes` | find foreign keys missing an index |
| `.recover` | salvage data from a corrupt database |
| `.parameter set @x 5` | bind parameters for testing queries |
| `.dbinfo` | file header details |

Dot commands are **CLI-only**. In application code, use SQL and PRAGMAs.

### 5.3 Python (`sqlite3`, standard library)

```python
import sqlite3

conn = sqlite3.connect("app.db", timeout=5.0, isolation_level=None)  # see note below
conn.row_factory = sqlite3.Row
for pragma in ("journal_mode = WAL", "synchronous = NORMAL", "foreign_keys = ON"):
    conn.execute(f"PRAGMA {pragma}")

# Always bind parameters: ? or :name. NEVER f-strings (SQL injection, lesson 04).
user = conn.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()

conn.execute("BEGIN IMMEDIATE")
try:
    conn.execute("INSERT INTO users (email, name) VALUES (:email, :name)", {"email": e, "name": n})
    conn.executemany("INSERT INTO tags (user_id, tag) VALUES (?, ?)", rows)
    conn.execute("COMMIT")
except Exception:
    conn.execute("ROLLBACK")
    raise
finally:
    conn.close()
```

**Python transaction gotchas:**
- In the **default** mode (`isolation_level=""`), the module silently issues `BEGIN` before
  `INSERT/UPDATE/DELETE` and **waits for you to call `conn.commit()`**. Closing without
  committing silently discards your writes (lesson 04 demonstrates this).
- `with conn:` commits on success and rolls back on exception, but it **does not close** the
  connection. Use `contextlib.closing(conn)` for that.
- `isolation_level=None` gives true autocommit, so you write `BEGIN`/`COMMIT` yourself:
  explicit and predictable. Python **3.12+** adds `sqlite3.connect(..., autocommit=False)`
  as the new recommended PEP 249 behavior.
- `executescript()` **commits any pending transaction first**.
- Connections refuse use from other threads (`check_same_thread=True`). Use one connection
  per thread.
- Python 3.12 deprecated the default `date`/`datetime` adapters. Store ISO strings explicitly.
- Async code: `aiosqlite`. ORMs: SQLAlchemy (`sqlite:///app.db`), and Django uses SQLite by default.

### 5.4 Node.js

```js
import { DatabaseSync } from 'node:sqlite';        // built in: Node 22.13+ / 23.4+ (experimental)
const db = new DatabaseSync('app.db');
db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;');
const get = db.prepare('SELECT * FROM users WHERE id = ?');
console.log(get.get(42));
```
For production, **`better-sqlite3`** (`npm i better-sqlite3`) is the long-standing standard.
It has a similar synchronous API plus `db.transaction(fn)` helpers. Bun has `bun:sqlite` built in.
Runnable example: [examples/node_example.mjs](examples/node_example.mjs).

### 5.5 Other languages

| Language | Library | Open a database |
| :--- | :--- | :--- |
| Java / Kotlin | `org.xerial:sqlite-jdbc` | `DriverManager.getConnection("jdbc:sqlite:app.db")` |
| Android | `android.database.sqlite`, Jetpack **Room** | `Room.databaseBuilder(ctx, AppDb::class.java, "app.db")` |
| C# / .NET | `Microsoft.Data.Sqlite`, EF Core | `new SqliteConnection("Data Source=app.db")` |
| Go | `modernc.org/sqlite` (pure Go) or `mattn/go-sqlite3` (cgo) | `sql.Open("sqlite", "app.db")` |
| Rust | `rusqlite`, `sqlx` | `Connection::open("app.db")?` |
| PHP | PDO | `new PDO('sqlite:app.db')` |
| Ruby | `sqlite3` gem, Rails | `SQLite3::Database.new("app.db")` |
| Swift / iOS | system `libsqlite3`, GRDB.swift | `try DatabaseQueue(path: "app.db")` |
| Browser | `@sqlite.org/sqlite-wasm` (OPFS persistence) | `new sqlite3.oo1.OpfsDb('/app.db')` |

**Connection pools** (Go's `database/sql`, Java pools, etc.) open *several* connections. PRAGMAs
like `foreign_keys` and `busy_timeout` are **per connection**, so set them in the connection
string or a connect hook, not once at startup.

### 5.6 Filenames and URIs

| Filename | Meaning |
| :--- | :--- |
| `app.db` | file on disk, created if missing |
| `:memory:` | private in-memory DB, gone when the connection closes |
| `""` (empty) | private temporary on-disk DB |
| `file:app.db?mode=ro` | read-only, and fails if missing (no accidental empty file) |
| `file:app.db?mode=rw` | read/write, but don't create |
| `file:memdb1?mode=memory&cache=shared` | in-memory DB shared by connections in one process |
| `file:app.db?immutable=1` | file will never change (read-only media), so skip locking |

URIs need URI support turned on in the driver (Python: `sqlite3.connect(uri, uri=True)`).

---

## 6. Production configuration

### 6.1 Recommended PRAGMAs

```sql
-- Once per database (persisted in the file):
PRAGMA journal_mode = WAL;            -- concurrent readers + writer, faster writes

-- On EVERY connection (not persisted):
PRAGMA busy_timeout = 5000;           -- wait up to 5 s for locks instead of failing
PRAGMA foreign_keys = ON;             -- enforce REFERENCES (off by default!)
PRAGMA synchronous = NORMAL;          -- with WAL: durable except the last commits on power loss.
                                      --   Use FULL if every commit must survive a power cut.
PRAGMA cache_size = -64000;           -- ~64 MB page cache (negative = KiB; default ~2 MB)
PRAGMA temp_store = MEMORY;           -- temp tables/sort spills in RAM
PRAGMA mmap_size = 268435456;         -- optional: 256 MB memory-mapped reads

-- Periodically, e.g. hourly or before closing a long-lived connection:
PRAGMA optimize;                      -- refresh planner statistics where useful
```

### 6.2 Architecture patterns for apps and servers

- **Use one writer.** Funnel writes through a single connection (or a mutex/queue) and give
  readers their own connections. This removes most `SQLITE_BUSY` errors by design.
- **`BEGIN IMMEDIATE` for every write transaction.** It avoids the deferred-upgrade trap.
- **Keep write transactions short.** Never hold one open across a network call, a user
  prompt, or a slow computation.
- **Close read transactions and cursors promptly.** A reader that never finishes stops
  checkpoints from completing, and the `-wal` file grows without bound ("checkpoint starvation").
- **Retry with backoff** on `SQLITE_BUSY`/`SQLITE_BUSY_SNAPSHOT` for the rare remaining cases.
- **Threads:** standard builds are thread-safe, but a single connection serializes its callers.
  Prefer one connection per thread.
- **Keep the DB on a local disk.** Not NFS/SMB network shares, and not a live cloud-sync folder
  (OneDrive, Dropbox, iCloud). This repo lives in OneDrive, so lesson 06 benchmarks in your
  temp folder.

### 6.3 Production checklist

- [ ] WAL mode on; `busy_timeout`, `foreign_keys`, `synchronous` set on every connection
- [ ] New tables are `STRICT`; money stored as INTEGER cents; times as ISO-8601 TEXT or epoch INTEGER
- [ ] All queries parameterized
- [ ] Writes use `BEGIN IMMEDIATE`, are short, and go through one writer
- [ ] Indexes checked with `EXPLAIN QUERY PLAN` for hot queries; `PRAGMA optimize` scheduled
- [ ] Backups use `.backup` / `VACUUM INTO` / the backup API / Litestream, **never a raw file copy**, and restores are tested
- [ ] Schema migrations tracked with `PRAGMA user_version`
- [ ] Database file on local disk, with permissions locked down (including `-wal`/`-shm`)
- [ ] You know which SQLite **version** production runs

---

## 7. Schema design the SQLite way

| Topic | Do this |
| :--- | :--- |
| Primary keys | `id INTEGER PRIMARY KEY` (exactly that spelling) aliases the rowid: fastest, auto-assigned. `INT PRIMARY KEY` is **not** an alias and even allows NULLs. |
| AUTOINCREMENT | Usually skip it. Without it, the id of a deleted *last* row can be reused; with it, ids are never reused but every insert also updates `sqlite_sequence`. |
| Text or composite PK | Consider `WITHOUT ROWID` to store rows directly in PK order. |
| Types | `STRICT` tables. Add `CHECK` constraints for domains: `CHECK (done IN (0,1))`, `CHECK (json_valid(data))`. |
| Booleans | `INTEGER NOT NULL CHECK (x IN (0,1))`. `TRUE`/`FALSE` are just 1/0. |
| Dates/times | ISO-8601 UTC text (`'2026-11-16T14:03:00Z'`) sorts correctly, or Unix epoch INTEGER. Use `date()`, `datetime()`, `strftime()`, `unixepoch()`, `julianday()`. |
| Money | INTEGER cents. `DECIMAL`/`NUMERIC` are floating point here. |
| Foreign keys | Declare them, turn on `PRAGMA foreign_keys`, and **index the child column** (`.lint fkey-indexes`). |
| JSON | TEXT column + `CHECK (json_valid(col))`; query with `->>`; index hot paths with expression indexes or generated columns. |
| Enums | `TEXT CHECK (status IN ('open','closed'))` or a lookup table. |

### Changing a table

`ALTER TABLE` supports only `RENAME TO`, `RENAME COLUMN`, `ADD COLUMN`, and `DROP COLUMN` (3.35+).
For anything else (changing a type, adding a constraint), **rebuild the table**. SQLite's DDL
is **transactional** (like PostgreSQL, unlike MySQL; see lesson 01), so the whole rebuild is atomic:

```sql
PRAGMA foreign_keys = OFF;          -- must be outside the transaction
BEGIN IMMEDIATE;
CREATE TABLE books_new (            -- 1. new definition
    id INTEGER PRIMARY KEY, title TEXT NOT NULL, rating_tenths INTEGER CHECK (rating_tenths BETWEEN 0 AND 50)
) STRICT;
INSERT INTO books_new (id, title, rating_tenths)                        -- 2. copy + transform
    SELECT id, title, CAST(round(rating * 10) AS INTEGER) FROM books;
DROP TABLE books;                                                       -- 3. swap
ALTER TABLE books_new RENAME TO books;
-- 4. recreate the indexes, triggers, and views that referenced the old table
PRAGMA foreign_key_check;           -- 5. verify nothing broke (should return no rows)
COMMIT;
PRAGMA foreign_keys = ON;
```

---

## 8. Performance

The numbers below are from lesson 06 on this machine. Your hardware will differ; the ratios are what matter.

| Lever | Effect | Notes |
| :--- | :--- | :--- |
| **Batch writes in one transaction** | **~140 → ~130,000 rows/s** (~900x) | Each COMMIT waits for fsync. Autocommit pays it per row. |
| `executemany` (+ WAL) | ~1.7x more on top | Less per-row driver overhead. Drivers also cache prepared statements, so don't rebuild SQL strings per row. |
| WAL + `synchronous=NORMAL` | ~80x faster autocommit | Fewer fsyncs; may lose the last commits on power loss, never corrupts |
| **The right index** | 69 ms → 0.4 ms lookup on 200k rows | Read plans with `EXPLAIN QUERY PLAN` |
| Covering / composite index in sort order | 79 ms → 0.4 ms, no temp sort | Equality columns first, then range/sort columns |
| `ANALYZE` / `PRAGMA optimize` | Better index choices | Stores stats in `sqlite_stat1` |
| `VACUUM` | Halved the file after deleting half the rows | Needs exclusive access + temp space |
| Bigger `cache_size`, `mmap_size` | Fewer disk reads | Matters once the DB exceeds the default ~2 MB cache |

**Reading `EXPLAIN QUERY PLAN`:**

| Plan text | Meaning |
| :--- | :--- |
| `SCAN users` | Reads every row. Fine for small tables, a red flag for big ones. |
| `SEARCH users USING INDEX idx (email=?)` | B-tree lookup through an index. |
| `SEARCH users USING INTEGER PRIMARY KEY (rowid=?)` | Direct rowid lookup, the fastest. |
| `USING COVERING INDEX` | Answered from the index alone. |
| `USE TEMP B-TREE FOR ORDER BY` | Had to sort; an index in that order would avoid it. |
| `AUTOMATIC COVERING INDEX` | SQLite built a temporary index for this one query, so you probably want a permanent one. |

Index tips: an index on `(a, b, c)` serves `WHERE a=?`, `WHERE a=? AND b=?`, and
`WHERE a=? ORDER BY b`, but **not** `WHERE b=?`. Use **partial indexes** (`... WHERE done = 0`)
for hot subsets and **expression indexes** (`ON t(lower(email))`, `ON t(data ->> '$.type')`)
for computed lookups. The query must use the *same expression*.

---

## 9. Modern SQL features (and which version you need)

| Feature | Since | Example |
| :--- | :--- | :--- |
| CTEs, `WITH RECURSIVE` | 3.8.3 | trees, series (lesson 03) |
| JSON functions (`json_extract`, `json_each`, ...) | 3.9 (built in by default since 3.38) | |
| UPSERT `ON CONFLICT DO UPDATE` | 3.24 | |
| Window functions | 3.25 | `rank() OVER (...)` |
| `RENAME COLUMN` | 3.25 | |
| Generated columns | 3.31 | `GENERATED ALWAYS AS (...) STORED` |
| `RETURNING` | 3.35 | `INSERT ... RETURNING id` |
| `DROP COLUMN`, built-in math functions | 3.35 | `sqrt()`, `log10()` |
| **`STRICT` tables** | **3.37** | |
| `->` / `->>` JSON operators, `unixepoch()` | 3.38 | `data ->> '$.user.id'` |
| `RIGHT` and `FULL OUTER JOIN` | 3.39 | |
| `string_agg`, `ORDER BY` inside aggregates | 3.44 | `string_agg(x, ',' ORDER BY x)` |
| JSONB (binary JSON storage) | 3.45 | `jsonb(...)` |
| `sqlite3_rsync` tool | 3.47 | efficient replica sync |

**Extensions built into most builds:** **FTS5** (full-text search with bm25 ranking),
**R\*Tree** (spatial indexes), JSON. Popular third-party ones: **sqlite-vec** (vector
similarity search, see topic 05 of this repo), the **sqlean** collection (regexp, crypto, stats),
and **SpatiaLite** (GIS).

What SQLite **doesn't** have: stored procedures (use your app language, or
`create_function` as in lesson 04), users/roles/GRANT, `ALTER COLUMN`, and server-side features
like LISTEN/NOTIFY or replication (see §10.3).

---

## 10. Operations

### 10.1 Backups (never copy a live database file)

A plain file copy of a database that's being written can capture a half-written state, or miss
recent commits that are still sitting in `-wal`. Use one of these instead:

| Method | Use when |
| :--- | :--- |
| `sqlite3 app.db ".backup backup.db"` | Ad-hoc / cron backups from the shell |
| `VACUUM INTO 'backup.db'` | Pure SQL, and the copy is compacted |
| Backup API (`conn.backup(dest)` in Python) | From inside your application (lesson 04) |
| `sqlite3_rsync app.db replica.db` (3.47+) | Efficiently refresh a copy, including over SSH |
| **Litestream** | Continuous streaming of the WAL to S3/GCS/Azure, with point-in-time restore |

Check backups with `PRAGMA integrity_check;` (thorough) or `PRAGMA quick_check;` (faster).
**Test restoring.**

### 10.2 Migrations

Track the schema version in the header field `PRAGMA user_version` and apply each step atomically:

```python
MIGRATIONS = [
    "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE) STRICT",
    "ALTER TABLE users ADD COLUMN name TEXT",
    "CREATE INDEX idx_users_name ON users (name)",
]

def migrate(conn):                      # conn opened with isolation_level=None
    current = conn.execute("PRAGMA user_version").fetchone()[0]
    for version, sql in enumerate(MIGRATIONS[current:], start=current + 1):
        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute(sql)
            conn.execute(f"PRAGMA user_version = {version}")  # PRAGMAs can't take ? parameters
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise
```
Tools like Alembic, Django migrations, Prisma, Drizzle, and Flyway support SQLite too. They
perform the table-rebuild dance (§7) for you.

### 10.3 Scaling beyond one machine

| Project | What it adds |
| :--- | :--- |
| **Litestream** | Streaming backup/replication to object storage |
| **LiteFS** | Replicates SQLite across machines via a FUSE filesystem (one primary writer) |
| **rqlite**, **dqlite** | Distributed, Raft-replicated SQLite with a network API |
| **Turso / libSQL** | Open-source fork of SQLite with a server mode, replication, and embedded replicas |
| **Cloudflare D1** | Managed serverless SQLite at the edge |

### 10.4 How databases get corrupted (and how to avoid it)

SQLite is extremely robust against crashes and power loss. Corruption almost always comes from
outside it:

1. Copying or syncing the file while it's being written (backup tools, **cloud-sync folders**).
2. Deleting or separating the `-wal`/`-journal` file from the `.db` (e.g. moving only `app.db`).
3. Network filesystems (NFS/SMB) with broken or missing file locking.
4. `PRAGMA synchronous = OFF` (or disks that ignore fsync) followed by a power loss.
5. Other code writing into the file directly, or a process `fork()`ing with an open connection.

Recovery: `sqlite3 broken.db ".recover" | sqlite3 fixed.db`.

---

## 11. Security

- **SQL injection:** always bind parameters. Identifiers (table/column names) can't be bound,
  so check them against an allowlist.
- **No authentication.** Access control is **file permissions**. Anyone who can read
  `app.db` (or its `-wal`) can read everything. Restrict the directory, not just the file.
- **Encryption at rest is not built in.** Options: SQLCipher (open source), SQLite Encryption
  Extension (official, commercial), SQLite3MultipleCiphers, or full-disk encryption.
- **Deleted data lingers** in free pages and the WAL. `PRAGMA secure_delete = ON` zeroes it,
  and `VACUUM` rewrites the file.
- **Opening untrusted database files** (uploads, downloads): a malicious file can contain
  hostile schema (triggers, views) or corrupt structures. Use `PRAGMA trusted_schema = OFF`,
  enable defensive mode (`SQLITE_DBCONFIG_DEFENSIVE`), set `PRAGMA cell_size_check = ON`,
  and run `PRAGMA quick_check` before trusting it.
- **Running untrusted SQL:** restrict it with an authorizer callback (`conn.set_authorizer`
  in Python), cap runtime with a progress handler, and keep extension loading disabled
  (the default).

---

## 12. Testing with SQLite

- **If production uses SQLite:** use a fresh `:memory:` DB (or a temp file) per test, with
  the **same PRAGMAs and the same SQLite version** as production. It's fast and fully isolated.
- **If production uses PostgreSQL/MySQL:** SQLite is fine for quick unit tests of plain SQL,
  but it **will hide bugs**: loose types, FKs off by default, case-insensitive `LIKE`, missing
  functions, different locking. Run integration tests against the real engine (e.g. with
  Testcontainers or Docker, as in lesson 01).

---

## 13. Limits

| Limit | Default |
| :--- | :--- |
| Max database size | ~281 TB |
| Max row / string / BLOB size | 1 GB (`SQLITE_MAX_LENGTH`) |
| Max columns per table | 2,000 |
| Max bound parameters per statement | 32,766 (999 before 3.32) |
| Max tables in a join | 64 |
| Max attached databases | 10 (up to 125 if compiled with a higher limit) |
| Concurrent writers | **1 per database file** |
| Concurrent readers | effectively unlimited |

The practical limits come well before these: one machine, and write throughput through a
single writer (typically thousands to tens of thousands of transactions per second on an SSD
in WAL mode, if they're short).

---

## 14. SQLite vs PostgreSQL vs MySQL

| | SQLite | PostgreSQL | MySQL (InnoDB) |
| :--- | :--- | :--- | :--- |
| Architecture | Library in your process | Client/server | Client/server |
| Setup | None | Install, configure, run, monitor | Install, configure, run, monitor |
| Storage | One portable file | Data directory | Data directory |
| Concurrent writers | 1 | Many (MVCC, row locks) | Many (MVCC, row locks) |
| Default isolation | Serializable | Read Committed | Repeatable Read |
| Type enforcement | Dynamic (`STRICT` opt-in) | Strict | Mostly strict (mode dependent) |
| Transactional DDL | **Yes** | Yes | No (implicit commit) |
| FK enforcement | **Opt-in per connection** | Always | Always |
| Users / permissions | None (file permissions) | Roles, GRANT, row-level security | Users, GRANT |
| Stored procedures | No (app-defined functions) | Yes (PL/pgSQL, ...) | Yes |
| Replication | External (Litestream, LiteFS, ...) | Built-in streaming/logical | Built-in |
| Query latency | Microseconds (function call) | Network round-trip | Network round-trip |
| Best for | Local/embedded data, single-server apps, files | Shared multi-user OLTP, complex workloads | Shared multi-user OLTP, web stacks |

---

## 15. Gotchas cheat sheet

| Gotcha | Fix |
| :--- | :--- |
| Foreign keys silently not enforced | `PRAGMA foreign_keys = ON` on **every** connection |
| `'abc'` stored in an INTEGER column | `STRICT` tables |
| `VARCHAR(10)` doesn't limit length | `CHECK (length(col) <= 10)` |
| `CAST('n/a' AS INTEGER)` = 0, not an error | Validate before casting (`GLOB '[0-9]*'`), or rely on STRICT |
| "database is locked" | WAL + `busy_timeout` + `BEGIN IMMEDIATE` + short transactions + one writer |
| Python writes vanish | You never called `commit()` (or use `isolation_level=None` + explicit BEGIN/COMMIT) |
| `INT PRIMARY KEY` allows NULL and isn't the rowid | Spell it `INTEGER PRIMARY KEY` |
| `"name"` matched as a string literal | Single quotes for values, double quotes only for identifiers |
| `LIKE` is case-insensitive, `=` is case-sensitive | Use `COLLATE NOCASE` deliberately; `upper()`/`lower()` are ASCII-only |
| `7/2 = 3` | Integer division. Use `7/2.0` or `CAST(x AS REAL)` |
| `0.1 + 0.2 != 0.3` (DECIMAL is a float) | Store money as INTEGER cents |
| `'2/1/2026' > '10/1/2026'` is true | Store dates as ISO-8601 |
| File doesn't shrink after DELETE | `VACUUM` / `auto_vacuum = INCREMENTAL` |
| `-wal` file grows forever | A long-lived read transaction is blocking checkpoints; close it |
| Copied DB is missing recent data or is corrupt | Never copy live files; use `.backup` / `VACUUM INTO` |
| Feature works in the CLI but not in the app | Different SQLite **version** bundled; check `sqlite_version()` |
| `ATTACH 'typo.db'` silently creates an empty file | `ATTACH 'file:x.db?mode=ro'` (or `mode=rw`) |
| `PRAGMA foreign_keys = ON` "does nothing" | It's a no-op inside a transaction; set it before `BEGIN` |

---

## 16. Lessons

Run everything **from this folder** (`02-sqlite/`). Lesson files write to `out/`, which git ignores.

| # | File | Topic | Run |
| :-: | :--- | :--- | :--- |
| 1 | [lessons/01_cli_tour.sql](lessons/01_cli_tour.sql) | CLI tour: CSV import, STRICT tables, output modes, query plans, export/backup | `sqlite3 out/library.db ".read lessons/01_cli_tour.sql"` |
| 2 | [lessons/02_types_and_gotchas.sql](lessons/02_types_and_gotchas.sql) | Type affinity, STRICT, FKs off, rowid, dates, text and math quirks, ALTER limits | `sqlite3 :memory: ".read lessons/02_types_and_gotchas.sql"` |
| 3 | [lessons/03_modern_sql.sql](lessons/03_modern_sql.sql) | CTEs, window functions, UPSERT, RETURNING, JSON, generated columns, FTS5, all JOINs, ATTACH | `sqlite3 :memory: ".read lessons/03_modern_sql.sql"` |
| 4 | [lessons/04_python_embedded.py](lessons/04_python_embedded.py) | Calling it from code: the file header, binding, injection, transactions, custom functions, backup | `python lessons/04_python_embedded.py` |
| 5 | [lessons/05_concurrency_wal.py](lessons/05_concurrency_wal.py) | Locks, rollback journal vs WAL, busy timeout, the DEFERRED trap, checkpoints | `python lessons/05_concurrency_wal.py` |
| 6 | [lessons/06_performance.py](lessons/06_performance.py) | Transaction batching, indexes + plans, ANALYZE, VACUUM | `python lessons/06_performance.py` |
| + | [examples/node_example.mjs](examples/node_example.mjs) | The same ideas from Node.js | `node examples/node_example.mjs` |

Lessons 1 to 3 need the `sqlite3` CLI (3.44+). Lessons 4 to 6 need only Python 3.8+, with no
installs. Read each file **before** running it and predict the output.

---

## 17. Exercises

Use `out/library.db` from lesson 01 (`sqlite3 out/library.db`).

1. Find the **oldest book in each genre**. Write it twice: once with a window function, once
   with SQLite's bare-column `min()` trick.
2. Add a `loans` table (`book_id`, `borrower`, `loaned_on`, `returned_on`) so that a book
   **can't be loaned out twice at the same time**, enforced by the database.
3. Make `SELECT title FROM books WHERE author_id = ? ORDER BY year` avoid both a table scan
   and a temp sort. Prove it with `EXPLAIN QUERY PLAN`.
4. Your web app logs `sqlite3.OperationalError: database is locked` under load. List five
   things to check.
5. Why does this lose data?
   ```python
   conn = sqlite3.connect("app.db")
   conn.execute("INSERT INTO users (email, name) VALUES (?, ?)", ("a@b.c", "A"))
   conn.close()
   ```
6. Change `books.rating` (REAL like `4.6`) into an INTEGER `rating_tenths` (`46`) without losing data.
7. A teammate's backup script runs `cp app.db /backups/` every night while the app (WAL mode)
   is running. What can go wrong, and what should it do instead?
8. SQLite or a client/server DB? (a) a mobile note-taking app, (b) a SaaS app on 5 servers
   behind a load balancer, (c) a CLI tool caching API responses, (d) a blog on one VPS with
   50k visits/day, (e) ad-hoc analysis of a 2 GB CSV.

<details>
<summary><b>Answers</b></summary>

1. ```sql
   -- Window function (portable to PostgreSQL):
   SELECT genre, title, year FROM (
     SELECT genre, title, year, row_number() OVER (PARTITION BY genre ORDER BY year) AS rn
     FROM books
   ) WHERE rn = 1;

   -- SQLite-only bare column: title comes from the row holding min(year)
   SELECT genre, title, min(year) AS year FROM books GROUP BY genre;
   ```
2. A **partial unique index** allows only one *open* loan per book:
   ```sql
   CREATE TABLE loans (
     id INTEGER PRIMARY KEY,
     book_id INTEGER NOT NULL REFERENCES books(id),
     borrower TEXT NOT NULL,
     loaned_on TEXT NOT NULL DEFAULT (date('now')),
     returned_on TEXT
   ) STRICT;
   CREATE UNIQUE INDEX one_open_loan_per_book ON loans (book_id) WHERE returned_on IS NULL;
   ```
   A second `INSERT` for the same book fails until the first loan gets a `returned_on`.
3. `CREATE INDEX idx_books_author_year ON books (author_id, year);`. The plan becomes
   `SEARCH books USING INDEX idx_books_author_year (author_id=?)` with no `USE TEMP B-TREE`.
   Equality column first, sort column second. Add `title` as a third column to make it covering.
4. (1) WAL mode on? (2) `busy_timeout` set on *every* connection, including pooled ones?
   (3) Write transactions use `BEGIN IMMEDIATE`? (4) Is a transaction held open too long,
   e.g. Python's implicit transaction never committed, an unclosed cursor, or network calls
   inside a transaction? (5) Are writes funneled through one writer? Bonus: is the file on a
   network or synced drive?
5. Python's default mode implicitly ran `BEGIN` before the `INSERT`. `close()` without
   `commit()` rolls it back. Fix: `conn.commit()`, `with conn:`, or `isolation_level=None`.
6. Use the table-rebuild procedure from §7: create `books_new` with
   `rating_tenths INTEGER CHECK (rating_tenths BETWEEN 0 AND 50)`, copy with
   `CAST(round(rating * 10) AS INTEGER)`, drop, rename, recreate indexes and the `book_list`
   view, run `PRAGMA foreign_key_check`, all inside one transaction.
7. Recent commits may still live only in `app.db-wal`, so the copy is missing them. A copy
   taken mid-checkpoint can also be internally inconsistent (corrupt). Use
   `sqlite3 app.db ".backup /backups/app.db"` or `VACUUM INTO`, or stream continuously with
   Litestream, then verify with `PRAGMA integrity_check`.
8. (a) SQLite: local per-device data. (b) Client/server (PostgreSQL), because many machines
   write over a network (or a distributed SQLite such as Turso or rqlite, with care). (c) SQLite.
   (d) SQLite in WAL mode handles that comfortably on one server. (e) SQLite works (`.import`,
   then index); for heavy aggregations over big files, DuckDB is the embedded *columnar*
   alternative.
</details>

---

## 18. Further reading

Official docs (sqlite.org): the docs are excellent and readable.
- [Appropriate uses](https://sqlite.org/whentouse.html) · [Architecture](https://sqlite.org/arch.html) · [File format](https://sqlite.org/fileformat2.html)
- [Datatypes](https://sqlite.org/datatype3.html) · [STRICT tables](https://sqlite.org/stricttables.html) · [Quirks](https://sqlite.org/quirks.html)
- [WAL](https://sqlite.org/wal.html) · [Locking](https://sqlite.org/lockingv3.html) · [Isolation](https://sqlite.org/isolation.html)
- [PRAGMAs](https://sqlite.org/pragma.html) · [SQL syntax](https://sqlite.org/lang.html) · [CLI](https://sqlite.org/cli.html)
- [Query planner](https://sqlite.org/queryplanner.html) · [EXPLAIN QUERY PLAN](https://sqlite.org/eqp.html) · [Many small queries are efficient](https://sqlite.org/np1queryprob.html)
- [How to corrupt a database](https://sqlite.org/howtocorrupt.html) · [Security](https://sqlite.org/security.html) · [Limits](https://sqlite.org/limits.html)
- [ALTER TABLE and schema changes](https://sqlite.org/lang_altertable.html)

Language docs: [Python `sqlite3`](https://docs.python.org/3/library/sqlite3.html) · [Node `node:sqlite`](https://nodejs.org/api/sqlite.html)

**Next topic:** Supabase → `03-supabase/`
