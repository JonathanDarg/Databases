#  Database Research & Learning Lab

repository! This workspace is dedicated to exploring, experimenting with, and mastering different database paradigms, architectures, and backend services. 

Whether it's relational consistency with traditional SQL, lightweight local storage with SQLite, modern Backend-as-a-Service (BaaS) platforms like Supabase and Firebase, or vector similarity search for AI, this repo serves as my centralized hub for database implementation and architecture analysis.

---

##  Research Areas & Technologies

Here is the roadmap of database technologies and platforms explored in this repository:

| Category | Technology / Database | Primary Use Case / Focus |
| :--- | :--- | :--- |
| **Relational (SQL)** | PostgreSQL, MySQL | ACID compliance, complex joins, relational modeling, advanced queries |
| **Embedded / Local (SQL)** | SQLite | Lightweight storage, mobile/desktop apps, zero-config testing |
| **Backend-as-a-Service (SQL)** | Supabase | Postgres-backed auth, real-time subscriptions, edge functions, row-level security |
| **Backend-as-a-Service (NoSQL)** | Firebase | Realtime Database, Firestore document storage, auth, hosting |
| **Key-Value & Caching** | Redis | High-throughput lookups, session management, caching patterns |
| **Vector Search** | Chroma, Pinecone, pgvector | LLM memory, semantic search, embeddings |
| **Graph & Time-Series** | Neo4j, TimescaleDB | Connected data structures, IoT metrics, financial tick data |

---

##  Repository Structure

```text
database/
├── 01-sql-relational/    # PostgreSQL & MySQL schemas, migrations, and complex queries
├── 02-sqlite/            # Lightweight database scripts and local file setups
├── 03-supabase/          # Supabase migrations, RLS policies, and client integration
├── 04-firebase/          # Firestore/Realtime DB structures and security rules
├── 05-nosql-vector/      # Document stores and vector embedding search pipelines
├── 06-timeseries-graph/  # Graph traversals and metric collection scripts
├── docker-compose.yml    # Local containerized database environments
└── README.md