-- 02_types_and_gotchas.sql  (sqlite3 command-line shell)
--
-- SQLite's type system and the behaviors that surprise people coming from
-- PostgreSQL/MySQL. Every section prints something worth stopping to read.
-- Errors below are EXPECTED. The CLI prints them and keeps going.
--
-- Run from the 02-sqlite folder (in-memory database, nothing written to disk):
--   sqlite3 :memory: ".read lessons/02_types_and_gotchas.sql"

.headers on
.mode box

.print '=== 1. Dynamic typing: the declared column type is only a suggestion ==='
CREATE TABLE loose (x INTEGER);
INSERT INTO loose VALUES (1), ('2'), ('three'), (4.0), (4.5), (x'CAFE'), (NULL);
SELECT quote(x) AS stored_value, typeof(x) AS storage_class FROM loose;
-- '2' became integer 2 and 4.0 became integer 4 (INTEGER affinity converts when lossless),
-- but 'three' and x'CAFE' were stored as-is. No error.

.print ''
.print '=== 2. Type affinity comes from substring rules on the type NAME ==='
--   contains "INT"                -> INTEGER affinity   (so "FLOATING POINT" is INTEGER!)
--   contains "CHAR"/"CLOB"/"TEXT" -> TEXT
--   contains "BLOB" or no type    -> BLOB (store exactly what you were given)
--   contains "REAL"/"FLOA"/"DOUB" -> REAL
--   anything else                 -> NUMERIC            (so "STRING" is NUMERIC!)
CREATE TABLE affinity_demo (
    a INT, b "FLOATING POINT", c STRING, d VARCHAR(3), e DECIMAL(10,2), f BLOB, g
);
INSERT INTO affinity_demo VALUES ('007', '007', '007', '007', '007', '007', '007');
SELECT typeof(a) || ' ' || a AS "INT",
       typeof(b) || ' ' || b AS "FLOATING POINT",
       typeof(c) || ' ' || c AS "STRING",
       typeof(d) || ' ' || d AS "VARCHAR(3)",
       typeof(e) || ' ' || e AS "DECIMAL",
       typeof(f) || ' ' || f AS "BLOB",
       typeof(g) || ' ' || g AS "(none)"
FROM affinity_demo;

.print 'VARCHAR(3) does not limit length either:'
INSERT INTO affinity_demo (d) VALUES ('way more than three characters');
SELECT d, length(d) AS len FROM affinity_demo WHERE length(d) > 3;

.print 'DECIMAL is not exact decimal math. It is stored as a float. Keep money in INTEGER cents:'
SELECT 0.1 + 0.2 AS float_sum, (0.1 + 0.2) = 0.3 AS equals_0_3, (10 + 20) = 30 AS cents_equal;

.print ''
.print '=== 3. STRICT tables (3.37+) enforce types like other databases ==='
CREATE TABLE strict_demo (id INTEGER PRIMARY KEY, qty INTEGER NOT NULL, note TEXT) STRICT;
INSERT INTO strict_demo (qty, note) VALUES ('5', 'text "5" converts losslessly, so it is allowed');
INSERT INTO strict_demo (qty, note) VALUES ('five', 'rejected');
INSERT INTO strict_demo (qty, note) VALUES (2.5, 'rejected: would lose data');
SELECT qty, typeof(qty) AS type, note FROM strict_demo;
.print 'STRICT only allows INT, INTEGER, REAL, TEXT, BLOB, ANY as types, so this fails:'
CREATE TABLE strict_bad (born DATE) STRICT;

.print ''
.print '=== 4. Foreign keys are OFF by default, per connection ==='
SELECT * FROM pragma_foreign_keys;
CREATE TABLE parent (id INTEGER PRIMARY KEY);
CREATE TABLE child  (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id));
INSERT INTO child (parent_id) VALUES (999);     -- succeeds: an orphan row!
PRAGMA foreign_keys = ON;
INSERT INTO child (parent_id) VALUES (998);     -- now rejected
.print 'foreign_key_check finds orphans that slipped in while FKs were off:'
PRAGMA foreign_key_check;

.print ''
.print '=== 5. INTEGER PRIMARY KEY vs INT PRIMARY KEY ==='
-- Every ordinary table has a hidden 64-bit "rowid" that is the B-tree key.
-- Exactly "INTEGER PRIMARY KEY" makes your column an ALIAS for it: auto-assigned, fastest lookup.
-- "INT PRIMARY KEY" is NOT an alias: it's a separate unique index, and, due to a
-- legacy bug kept for compatibility, it even allows NULLs.
CREATE TABLE k1 (id INTEGER PRIMARY KEY, v TEXT);
CREATE TABLE k2 (id INT     PRIMARY KEY, v TEXT);
INSERT INTO k1 (v) VALUES ('auto-assigned id');
INSERT INTO k2 (v) VALUES ('NULL primary key!');
INSERT INTO k2 (v) VALUES ('another NULL primary key!');
SELECT 'k1' AS tbl, rowid, quote(id) AS id, v FROM k1
UNION ALL
SELECT 'k2', rowid, quote(id), v FROM k2;

.print ''
.print '=== 6. rowid reuse vs AUTOINCREMENT ==='
CREATE TABLE plain   (id INTEGER PRIMARY KEY,               v TEXT);
CREATE TABLE autoinc (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
INSERT INTO plain   (v) VALUES ('a'), ('b'), ('c');
INSERT INTO autoinc (v) VALUES ('a'), ('b'), ('c');
DELETE FROM plain   WHERE id = 3;
DELETE FROM autoinc WHERE id = 3;
INSERT INTO plain   (v) VALUES ('d');
INSERT INTO autoinc (v) VALUES ('d');
SELECT 'plain' AS tbl, id AS id_of_d FROM plain WHERE v = 'd'
UNION ALL
SELECT 'autoinc', id FROM autoinc WHERE v = 'd';
-- plain reused id 3 (it picks max(rowid)+1). AUTOINCREMENT never reuses, at the cost
-- of maintaining the sqlite_sequence table. Only use it if reuse would be a bug.
SELECT * FROM sqlite_sequence;

.print ''
.print '=== 7. No BOOLEAN or DATE types. Use INTEGER and TEXT/INTEGER ==='
SELECT TRUE AS true_kw, FALSE AS false_kw, typeof(TRUE) AS type;
SELECT date('now')                    AS today_utc,
       datetime('now', 'localtime')   AS local_now,
       date('now', '+30 days')        AS in_30_days,
       unixepoch('now')               AS unix_seconds,     -- unixepoch() needs 3.38+
       strftime('%Y-%m', 'now')       AS year_month;
SELECT julianday('2026-12-25') - julianday('2026-11-16') AS days_between;
.print 'Text dates only sort/compare correctly in ISO-8601 (YYYY-MM-DD) format:'
SELECT '2026-02-01' > '2026-10-01' AS iso_feb_after_oct,       -- 0 (correct)
       '2/1/2026'   > '10/1/2026'  AS us_feb_after_oct;        -- 1 (wrong!)

.print ''
.print '=== 8. Text quirks ==='
SELECT 'ABC' LIKE 'abc'                 AS like_ignores_case,
       'ABC' = 'abc'                    AS equals_is_case_sensitive,
       'ABC' = 'abc' COLLATE NOCASE     AS nocase_collation,
       upper('straße')                  AS upper_ascii_only,
       lower('ÉCOLE')                   AS lower_ascii_only,
       length('café')                   AS chars,
       length(CAST('café' AS BLOB))     AS bytes;

.print ''
.print '=== 9. Double quotes are for identifiers, single quotes are for strings ==='
CREATE TABLE people (name TEXT);
INSERT INTO people VALUES ('Ada');
-- For backwards compatibility, many SQLite builds treat "x" as a STRING LITERAL when no
-- column named x exists (a misfeature called "DQS"). The danger: a MISSPELLED column name
-- silently becomes a string instead of raising "no such column".
.print 'Typo in a column name (nmae instead of name):'
SELECT "nmae" AS supposed_to_be_name FROM people;
.print 'If that printed the word nmae instead of an error, this build has DQS enabled.'
.print 'Always: single quotes for values, double quotes only for identifiers.'

.print ''
.print '=== 10. Math and aggregate quirks ==='
SELECT 7 / 2 AS int_division, 7 / 2.0 AS real_division, 7 % 3 AS modulo,
       CAST('12abc' AS INTEGER) AS cast_prefix, '10' + 5 AS text_plus_int;
CREATE TABLE scores (player TEXT, pts INTEGER);
INSERT INTO scores VALUES ('ana', 10), ('ben', 42), ('cy', 7);
.print 'A "bare column" next to max()/min() comes from the row that had the max (SQLite-only):'
SELECT player, max(pts) FROM scores;          -- PostgreSQL would reject this query

.print ''
.print '=== 11. ALTER TABLE is limited ==='
ALTER TABLE scores ADD COLUMN team TEXT DEFAULT 'red';      -- ok
ALTER TABLE scores RENAME COLUMN pts TO points;             -- ok (3.25+)
ALTER TABLE scores DROP COLUMN team;                        -- ok (3.35+)
ALTER TABLE scores ALTER COLUMN points TYPE REAL;           -- not supported: syntax error
.print 'Changing a column type or constraint = rebuild the table (see README, "Changing a table").'
.schema scores
