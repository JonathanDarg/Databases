// node_example.mjs: the same embedded-database idea from JavaScript.
//
// Node 22.13+ ships a built-in SQLite module (node:sqlite). No npm install needed.
// It is still marked experimental, so Node prints an ExperimentalWarning.
// For production Node apps, the long-standing choice is the `better-sqlite3` package
// (npm install better-sqlite3), which has a very similar synchronous API.
//
// Run from the 02-sqlite folder:
//   node examples/node_example.mjs

import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';

mkdirSync('out', { recursive: true });
const db = new DatabaseSync('out/node_todos.db');   // use ':memory:' for a throwaway DB

// Per-connection setup (same as every other language)
db.exec(`
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA foreign_keys = ON;
  PRAGMA busy_timeout = 5000;

  DROP TABLE IF EXISTS todos;
  CREATE TABLE todos (
    id    INTEGER PRIMARY KEY,
    title TEXT    NOT NULL,
    done  INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1))
  ) STRICT;
`);

console.log('SQLite version bundled with this Node:', db.prepare('SELECT sqlite_version() AS v').get().v);

// Prepared statements: compile once, run many times. Values are always bound, never concatenated.
const insert = db.prepare('INSERT INTO todos (title) VALUES (?) RETURNING id');
const markDone = db.prepare('UPDATE todos SET done = 1 WHERE id = :id');
const listOpen = db.prepare('SELECT id, title FROM todos WHERE done = 0 ORDER BY id');

// A transaction: BEGIN ... COMMIT, ROLLBACK on error
function addMany(titles) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const ids = titles.map((t) => insert.get(t).id);
    db.exec('COMMIT');
    return ids;
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

const ids = addMany(['learn WAL mode', 'read EXPLAIN QUERY PLAN', 'set busy_timeout']);
console.log('Inserted ids:', ids);

markDone.run({ id: ids[0] });   // named parameter
console.log('Open todos:', listOpen.all());

try {
  addMany(['this one is fine', null]);   // NOT NULL violation -> whole batch rolls back
} catch (err) {
  console.log('Rolled back batch:', err.message);
}
console.log('Row count after failed batch:', db.prepare('SELECT count(*) AS n FROM todos').get().n);

db.close();
