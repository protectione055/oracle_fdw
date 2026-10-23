/*
 * Reproduce the PostgreSQL whole-row type mismatch with a ROWID scan tuple.
 * Run with psql in a database containing oracle_fdw and the regression server
 * "oracle" (SCOTT/tiger), for example after make installcheck:
 * psql -X -d contrib_regression -f sql/repro/oracle_rowid_whole_row.sql
 *
 * Expected error: attribute 1 of type record has wrong type.
 * The script rolls back the UPDATE and removes its test tables.
 */
\set ON_ERROR_STOP on
SELECT oracle_execute('oracle', 'CREATE TABLE SCOTT.FDW_ROWID_WHOLE_ROW (id NUMBER)');
SELECT oracle_execute('oracle', 'INSERT INTO SCOTT.FDW_ROWID_WHOLE_ROW VALUES (1)');
CREATE FOREIGN TABLE rowid_whole_row (id int) SERVER oracle
   OPTIONS (table '(SELECT ID FROM SCOTT.FDW_ROWID_WHOLE_ROW)');
BEGIN;
SAVEPOINT before_update;
\set ON_ERROR_STOP off
UPDATE rowid_whole_row t SET id = (row_to_json(t) ->> 'id')::int RETURNING id;
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT before_update;
ROLLBACK;
DROP FOREIGN TABLE rowid_whole_row;
SELECT oracle_execute('oracle', 'DROP TABLE SCOTT.FDW_ROWID_WHOLE_ROW PURGE');
