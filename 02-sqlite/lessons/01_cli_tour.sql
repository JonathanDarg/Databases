-- 01_cli_tour.sql  (sqlite3 command-line shell)
--
-- A tour of the sqlite3 CLI: import a CSV, normalize it into typed tables, query it,
-- read query plans, inspect the schema, and export/back up the result.
--
-- Run from the 02-sqlite folder (works in PowerShell, cmd, and bash):
--   sqlite3 out/library.db ".read lessons/01_cli_tour.sql"
-- Then explore what it built:
--   sqlite3 out/library.db
--
-- Lines starting with "." are DOT COMMANDS. The CLI handles them itself; they are not
-- SQL, so they don't work from Python/Node/etc. Everything else is plain SQL.

.headers on
.mode box

.print '=== 1. Version and attached databases ==='
SELECT sqlite_version() AS version;
.databases

.print ''
.print '=== 2. Import a CSV into a staging table ==='
-- When the table doesn't exist, .import creates it from the header row and
-- every column becomes TEXT. That's why you import into a STAGING table first.
DROP VIEW  IF EXISTS book_list;
DROP TABLE IF EXISTS books;
DROP TABLE IF EXISTS authors;
DROP TABLE IF EXISTS staging_books;
.import --csv data/books.csv staging_books
.schema staging_books
SELECT title, year, typeof(year) AS year_type, pages FROM staging_books LIMIT 3;

.print ''
.print '=== 3. Normalize into typed STRICT tables ==='
PRAGMA foreign_keys = ON;   -- OFF by default in SQLite! Must be set on EVERY connection.

CREATE TABLE authors (
    id   INTEGER PRIMARY KEY,               -- alias for the built-in rowid: auto-assigned
    name TEXT    NOT NULL UNIQUE
) STRICT;                                   -- STRICT = enforce column types (3.37+)

CREATE TABLE books (
    id        INTEGER PRIMARY KEY,
    title     TEXT    NOT NULL,
    author_id INTEGER NOT NULL REFERENCES authors(id),
    year      INTEGER NOT NULL,
    genre     TEXT    NOT NULL,
    pages     INTEGER,                      -- NULL means "unknown"
    rating    REAL    CHECK (rating BETWEEN 0 AND 5)
) STRICT;

INSERT INTO authors (name)
SELECT DISTINCT author FROM staging_books ORDER BY author;

INSERT INTO books (title, author_id, year, genre, pages, rating)
SELECT s.title,
       a.id,
       CAST(s.year AS INTEGER),
       s.genre,
       CASE WHEN s.pages GLOB '[0-9]*' THEN CAST(s.pages AS INTEGER) END,  -- 'n/a' -> NULL
       CAST(s.rating AS REAL)
FROM staging_books s
JOIN authors a ON a.name = s.author;

.print 'Careful: CAST of non-numeric text silently returns 0 instead of raising an error:'
SELECT 'n/a' AS raw_value, CAST('n/a' AS INTEGER) AS cast_result;

DROP TABLE staging_books;
.print 'Tables now:'
.tables

.print ''
.print '=== 4. Output modes: one query, many formats ==='
CREATE VIEW book_list AS
SELECT b.title, a.name AS author, b.year, b.genre, b.pages, b.rating
FROM books b JOIN authors a ON a.id = b.author_id;

.print '-- .mode box'
SELECT title, author, year FROM book_list ORDER BY year LIMIT 3;
.mode markdown
.print '-- .mode markdown (paste straight into a README)'
SELECT title, author, year FROM book_list ORDER BY year LIMIT 3;
.mode json
.print '-- .mode json'
SELECT title, author, year FROM book_list ORDER BY year LIMIT 3;
.mode csv
.print '-- .mode csv'
SELECT title, author, year FROM book_list ORDER BY year LIMIT 3;
.mode line
.print '-- .mode line (one column per line, good for wide rows)'
SELECT * FROM book_list WHERE title = 'Dune';
.mode box

.print ''
.print '=== 5. Analytics: aggregate + window function ==='
SELECT author,
       count(*)                                  AS books,
       round(avg(rating), 2)                     AS avg_rating,
       rank() OVER (ORDER BY avg(rating) DESC)   AS rank
FROM book_list
GROUP BY author
ORDER BY rank
LIMIT 5;

.print ''
.print '=== 6. Query plans: SCAN (read every row) vs SEARCH (use an index) ==='
.print '-- before the index:'
EXPLAIN QUERY PLAN SELECT title FROM books WHERE genre = 'Fantasy' AND year < 1960;
CREATE INDEX idx_books_genre_year ON books (genre, year);
.print '-- after CREATE INDEX idx_books_genre_year ON books (genre, year):'
EXPLAIN QUERY PLAN SELECT title FROM books WHERE genre = 'Fantasy' AND year < 1960;
.print '(Tip: ".eqp on" prints the plan automatically before every query.)'

.print ''
.print '=== 7. Schema introspection ==='
.schema books
.indexes books
.print '-- sqlite_schema is the table SQLite stores the schema in:'
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY type, name;
.print '-- PRAGMA table_info / foreign_key_list (also usable as table-valued functions):'
SELECT cid, name, type, "notnull", pk FROM pragma_table_info('books');
SELECT "table", "from", "to" FROM pragma_foreign_key_list('books');

.print ''
.print '=== 8. Export, dump, back up ==='
.headers on
.mode csv
.once out/fantasy_books.csv
SELECT * FROM book_list WHERE genre = 'Fantasy';
.mode box
.print 'Wrote out/fantasy_books.csv'
.backup out/library_backup.db
.print 'Wrote out/library_backup.db (a safe, consistent copy. Never copy a live .db file with cp/Explorer)'
.print '-- .dump turns tables into portable SQL text (this is the authors table):'
.dump authors

.print ''
.print '=== 9. File-level facts ==='
SELECT * FROM pragma_page_size, pragma_page_count, pragma_freelist_count, pragma_journal_mode;
PRAGMA integrity_check;

.print ''
.print 'Done. Open the database yourself with:   sqlite3 out/library.db'
.print 'Try: .tables   .schema   SELECT * FROM book_list;   .help'
