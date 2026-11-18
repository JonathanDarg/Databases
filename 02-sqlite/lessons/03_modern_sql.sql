-- 03_modern_sql.sql  (sqlite3 command-line shell, 3.44+ recommended)
--
-- "Lite" does not mean "limited SQL". This lesson covers CTEs, window functions,
-- UPSERT, RETURNING, JSON, generated columns, partial/expression indexes, full-text
-- search, every JOIN type, and ATTACH.
--
-- Run from the 02-sqlite folder (run lesson 01 first; section 10 reads its database):
--   sqlite3 :memory: ".read lessons/03_modern_sql.sql"

.headers on
.mode box
SELECT sqlite_version() AS running_on;

.print ''
.print '=== 1. Recursive CTEs: generate rows, walk a hierarchy ==='
WITH RECURSIVE n(x) AS (
    SELECT 1
    UNION ALL
    SELECT x + 1 FROM n WHERE x < 5
)
SELECT x, x * x AS square FROM n;

CREATE TABLE employees (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    manager_id INTEGER REFERENCES employees(id)
);
INSERT INTO employees VALUES
    (1, 'Ava', NULL), (2, 'Ben', 1), (3, 'Cleo', 1),
    (4, 'Dev', 2),    (5, 'Eli', 2), (6, 'Fay', 4);

WITH RECURSIVE chain(id, name, depth, path) AS (
    SELECT id, name, 0, name FROM employees WHERE manager_id IS NULL
    UNION ALL
    SELECT e.id, e.name, c.depth + 1, c.path || ' > ' || e.name
    FROM employees e JOIN chain c ON e.manager_id = c.id
)
SELECT substr('            ', 1, depth * 2) || name AS org_chart, depth, path
FROM chain ORDER BY path;

.print ''
.print '=== 2. Window functions: running totals, ranks, moving averages, lag ==='
CREATE TABLE sales (day TEXT, region TEXT, amount INTEGER);
INSERT INTO sales VALUES
    ('2026-01-01', 'east', 100), ('2026-01-02', 'east', 150), ('2026-01-03', 'east',  90),
    ('2026-01-01', 'west', 200), ('2026-01-02', 'west',  50), ('2026-01-03', 'west', 300);

SELECT day, region, amount,
       sum(amount) OVER (PARTITION BY region ORDER BY day)            AS running_total,
       rank()      OVER (PARTITION BY day ORDER BY amount DESC)       AS rank_that_day,
       round(avg(amount) OVER (PARTITION BY region ORDER BY day
                               ROWS BETWEEN 1 PRECEDING AND CURRENT ROW), 1) AS moving_avg,
       amount - lag(amount) OVER (PARTITION BY region ORDER BY day)   AS change
FROM sales
ORDER BY region, day;

.print ''
.print '=== 3. UPSERT (insert-or-update) and RETURNING ==='
CREATE TABLE inventory (sku TEXT PRIMARY KEY, qty INTEGER NOT NULL CHECK (qty >= 0)) STRICT;
INSERT INTO inventory VALUES ('apple', 10);

.print 'apple exists -> update it; pear is new -> insert it. RETURNING shows the result:'
INSERT INTO inventory (sku, qty) VALUES ('apple', 5), ('pear', 3)
    ON CONFLICT (sku) DO UPDATE SET qty = qty + excluded.qty
    RETURNING sku, qty;

UPDATE inventory SET qty = qty - 2 WHERE sku = 'apple' RETURNING sku, qty AS remaining;
DELETE FROM inventory WHERE qty < 5 RETURNING sku AS deleted;

.print ''
.print '=== 4. JSON: validate, query, explode, aggregate, index ==='
CREATE TABLE events (
    id      INTEGER PRIMARY KEY,
    payload TEXT NOT NULL CHECK (json_valid(payload))
);
INSERT INTO events (payload) VALUES
    ('{"type":"click","user":{"id":7,"country":"US"},"tags":["promo","mobile"]}'),
    ('{"type":"view", "user":{"id":9,"country":"DE"},"tags":[]}'),
    ('{"type":"click","user":{"id":7,"country":"US"},"tags":["mobile"]}');
INSERT INTO events (payload) VALUES ('{not json');   -- rejected by the CHECK

SELECT id,
       json_extract(payload, '$.type')        AS type,        -- works on any version
       payload ->> '$.user.country'           AS country,     -- ->> operator needs 3.38+
       json_array_length(payload, '$.tags')   AS n_tags
FROM events;

.print 'json_each turns a JSON array into rows:'
SELECT e.id, t.value AS tag
FROM events e, json_each(e.payload, '$.tags') t;

.print 'json_group_array / json_object turn rows back into JSON:'
SELECT payload ->> '$.user.id' AS user_id,
       json_group_array(payload ->> '$.type') AS event_types,
       json_object('n', count(*))             AS summary
FROM events
GROUP BY user_id;

.print 'An expression index makes a JSON field searchable without a table scan:'
CREATE INDEX idx_events_type ON events (payload ->> '$.type');
EXPLAIN QUERY PLAN SELECT id FROM events WHERE payload ->> '$.type' = 'click';

.print ''
.print '=== 5. Generated columns ==='
CREATE TABLE orders (
    id          INTEGER PRIMARY KEY,
    qty         INTEGER NOT NULL,
    unit_cents  INTEGER NOT NULL,
    total_cents INTEGER GENERATED ALWAYS AS (qty * unit_cents) STORED,   -- computed on write
    data        TEXT,
    customer    TEXT    GENERATED ALWAYS AS (data ->> '$.customer') VIRTUAL  -- computed on read
);
INSERT INTO orders (qty, unit_cents, data) VALUES
    (3,  250, '{"customer":"acme"}'),
    (1, 9999, '{"customer":"globex"}');
SELECT id, qty, unit_cents, total_cents,
       printf('$%.2f', total_cents / 100.0) AS total, customer
FROM orders;

.print ''
.print '=== 6. Partial index: index only the rows you actually query ==='
CREATE TABLE tasks (id INTEGER PRIMARY KEY, title TEXT, assignee TEXT, done INTEGER NOT NULL DEFAULT 0);
CREATE INDEX idx_open_tasks ON tasks (assignee) WHERE done = 0;
EXPLAIN QUERY PLAN SELECT id, title FROM tasks WHERE assignee = 'ben' AND done = 0;
.print '(The index stays small because finished tasks are never put in it.)'

.print ''
.print '=== 7. Full-text search with FTS5 ==='
CREATE VIRTUAL TABLE docs USING fts5(title, body);
INSERT INTO docs VALUES
    ('WAL mode',         'Write-ahead logging lets readers and a writer work concurrently.'),
    ('Rollback journal', 'The original journal copies pages before changing them, so a writer blocks readers.'),
    ('Vacuum',           'VACUUM rebuilds the database file and reclaims free pages.'),
    ('Indexes',          'An index is a separate B-tree that makes searching faster for readers.'),
    ('Pager',            'The pager manages the page cache, file locking, and the journal.'),
    ('Checkpoint',       'A checkpoint copies pages from the WAL file back into the main database file.'),
    ('Busy timeout',     'A busy timeout makes a connection wait for a lock instead of failing immediately.'),
    ('B-trees',          'Tables and indexes are stored as B-trees made of fixed-size pages.');

.print 'Ranked search with highlighted matches (lower bm25 = more relevant):'
SELECT title, highlight(docs, 1, '[', ']') AS snippet, round(bm25(docs), 3) AS score
FROM docs WHERE docs MATCH 'readers writer' ORDER BY bm25(docs);
.print 'Prefix, phrase, and column-filter queries:'
SELECT 'writ*'                         AS query, group_concat(title, ' | ') AS matches FROM docs WHERE docs MATCH 'writ*'
UNION ALL
SELECT '"blocks readers"',               group_concat(title, ' | ') FROM docs WHERE docs MATCH '"blocks readers"'
UNION ALL
SELECT 'title:vacuum OR body:index',     group_concat(title, ' | ') FROM docs WHERE docs MATCH 'title:vacuum OR body:index';

.print ''
.print '=== 8. Every JOIN type (RIGHT and FULL OUTER need 3.39+) ==='
CREATE TABLE l (k INTEGER, lv TEXT);
CREATE TABLE r (k INTEGER, rv TEXT);
INSERT INTO l VALUES (1, 'L1'), (2, 'L2');
INSERT INTO r VALUES (2, 'R2'), (3, 'R3');
SELECT 'INNER' AS join_type, l.k AS lk, lv, r.k AS rk, rv FROM l INNER JOIN r ON l.k = r.k
UNION ALL SELECT 'LEFT',  l.k, lv, r.k, rv FROM l LEFT  JOIN r ON l.k = r.k
UNION ALL SELECT 'RIGHT', l.k, lv, r.k, rv FROM l RIGHT JOIN r ON l.k = r.k
UNION ALL SELECT 'FULL',  l.k, lv, r.k, rv FROM l FULL  JOIN r ON l.k = r.k;

.print ''
.print '=== 9. Newer conveniences: string_agg with ORDER BY (3.44+), math functions ==='
SELECT region, string_agg(amount, ', ' ORDER BY amount DESC) AS amounts_high_to_low
FROM sales GROUP BY region;
SELECT round(sqrt(2), 4) AS sqrt2, round(pi(), 4) AS pi, log10(1000) AS log10_1000,
       iif(1 > 0, 'yes', 'no') AS iif_demo;

.print ''
.print '=== 10. ATTACH: one connection, several database files, cross-file joins ==='
-- mode=ro opens read-only and fails instead of silently creating an empty file.
ATTACH DATABASE 'file:out/library.db?mode=ro' AS lib;
SELECT genre, count(*) AS books FROM lib.books GROUP BY genre ORDER BY books DESC;
.databases
DETACH DATABASE lib;
