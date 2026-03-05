-- pg_hebrew_sql installer
-- Run: psql -d your_database -f sql/install.sql

\echo 'Creating schema and tables...'
\i sql/001_schema.sql

\echo 'Creating functions...'
\i sql/002_functions.sql

\echo 'Loading data (this may take a minute)...'
\i sql/004_data.sql

\echo 'Running tests...'
\i sql/005_tests.sql

\echo 'pg_hebrew_sql installed successfully!'
