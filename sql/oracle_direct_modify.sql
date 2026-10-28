\set VERBOSITY terse
\set QUIET 0
SET client_min_messages = WARNING;
SET DateStyle = 'ISO, MDY';

SELECT oracle_execute('oracle', 'CREATE TABLE scott.direct_test (id NUMBER(9), val NUMBER, txt VARCHAR2(100))');
CREATE FOREIGN TABLE direct_test (id integer, val numeric, txt text)
  SERVER oracle OPTIONS (schema 'SCOTT', table 'DIRECT_TEST');
INSERT INTO direct_test VALUES (1, 10, 'one'), (2, 20, 'two'), (3, 30, 'three');

-- Eligible statements show Foreign Update/Delete and the remote DML.
EXPLAIN (COSTS OFF)
UPDATE direct_test SET val = 25 WHERE id >= 2;
EXPLAIN (COSTS OFF)
DELETE FROM direct_test WHERE id = 1;
-- EXPLAIN must leave the data intact.
SELECT * FROM direct_test ORDER BY id;
BEGIN;
EXPLAIN (COSTS OFF)
UPDATE direct_test SET val = 25, txt = 'changed' WHERE id >= 2;
UPDATE direct_test SET val = 25, txt = 'changed' WHERE id >= 2;
SELECT * FROM direct_test ORDER BY id;
SAVEPOINT before_delete;
DELETE FROM direct_test WHERE id >= 2;
SELECT * FROM direct_test ORDER BY id;
ROLLBACK TO before_delete;
SELECT count(*) FROM direct_test;
UPDATE direct_test SET val = 0 WHERE id = 99;
DELETE FROM direct_test WHERE id = 99;
ROLLBACK;

-- EXPLAIN ANALYZE reports affected rows and executes each DML once.
CREATE FUNCTION direct_analyze(sql text) RETURNS bigint LANGUAGE plpgsql AS
$$DECLARE p json;
BEGIN
  EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON, TIMING OFF) ' || sql INTO p;
  RETURN (p->0->'Plan'->'Plans'->0->>'Actual Rows')::bigint;
END$$;
BEGIN;
SELECT direct_analyze('UPDATE direct_test SET val = 25 WHERE id >= 2') AS updated_rows;
SELECT val FROM direct_test ORDER BY id;
SELECT direct_analyze('DELETE FROM direct_test WHERE id >= 2') AS deleted_rows;
SELECT direct_analyze('DELETE FROM direct_test WHERE id >= 2') AS zero_rows;
SELECT count(*) FROM direct_test;
ROLLBACK;
DROP FUNCTION direct_analyze(text);

-- Parameterized WHERE and SET clauses share one bind namespace.
PREPARE direct_update(integer, numeric) AS UPDATE direct_test SET val = $2 WHERE id = $1;
BEGIN;
EXPLAIN (COSTS OFF) EXECUTE direct_update(1, 101);
EXECUTE direct_update(1, 101);
EXECUTE direct_update(2, 202);
EXECUTE direct_update(3, 303);
EXECUTE direct_update(1, 111);
EXECUTE direct_update(2, 222);
EXECUTE direct_update(3, 333);
EXECUTE direct_update(1, NULL);
SELECT * FROM direct_test ORDER BY id;
ROLLBACK;
DEALLOCATE direct_update;

-- InitPlan parameters and data-modifying CTE command tags.
BEGIN;
UPDATE direct_test SET val = (SELECT 99::numeric) WHERE id = (SELECT 1);
WITH d AS (DELETE FROM direct_test WHERE id = 2) SELECT 42 AS answer;
SELECT * FROM direct_test ORDER BY id;
ROLLBACK;

-- Whole-table DML, including a zero-row repeat.
BEGIN;
EXPLAIN (COSTS OFF)
UPDATE direct_test SET txt = 'all';
UPDATE direct_test SET txt = 'all';
DELETE FROM direct_test;
DELETE FROM direct_test;
ROLLBACK;

-- Column expressions, RETURNING, local conditions and joins use row-by-row execution.
EXPLAIN (COSTS OFF)
UPDATE direct_test SET val = val + 1;
EXPLAIN (COSTS OFF)
UPDATE direct_test SET txt = upper(txt);
EXPLAIN (COSTS OFF)
UPDATE direct_test SET val = 1, txt = upper(txt);
EXPLAIN (COSTS OFF)
UPDATE direct_test SET val = val;
EXPLAIN (COSTS OFF)
UPDATE direct_test SET val = val + 1 RETURNING val;
EXPLAIN (COSTS OFF)
DELETE FROM direct_test RETURNING id;
EXPLAIN (COSTS OFF)
UPDATE direct_test SET val = random();
EXPLAIN (COSTS OFF)
DELETE FROM direct_test WHERE id::text LIKE '1%';
EXPLAIN (COSTS OFF)
UPDATE direct_test SET val = x.val FROM direct_test x WHERE direct_test.id = x.id;
BEGIN;
UPDATE direct_test SET val = val + 1 WHERE id = 1 RETURNING id, val;
DELETE FROM direct_test WHERE id = 2 RETURNING id;
DELETE FROM direct_test WHERE id::text LIKE '3%';
SELECT * FROM direct_test ORDER BY id;
ROLLBACK;

CREATE FUNCTION direct_row_trigger() RETURNS trigger LANGUAGE plpgsql AS
$$BEGIN NEW.val := NEW.val + 100; RETURN NEW; END$$;
CREATE TRIGGER direct_row BEFORE UPDATE ON direct_test
  FOR EACH ROW EXECUTE PROCEDURE direct_row_trigger();
EXPLAIN (COSTS OFF)
UPDATE direct_test SET val = 1;
BEGIN;
UPDATE direct_test SET val = val + 1 WHERE id = 1;
SELECT val FROM direct_test WHERE id = 1;
ROLLBACK;
DROP TRIGGER direct_row ON direct_test;
DROP FUNCTION direct_row_trigger();

-- Statement triggers still run around direct DML.
CREATE TEMP TABLE direct_events (event text);
CREATE FUNCTION direct_statement_trigger() RETURNS trigger LANGUAGE plpgsql AS
$$BEGIN INSERT INTO direct_events VALUES (TG_WHEN); RETURN NULL; END$$;
CREATE TRIGGER direct_before BEFORE DELETE ON direct_test
  FOR EACH STATEMENT EXECUTE PROCEDURE direct_statement_trigger();
CREATE TRIGGER direct_after AFTER DELETE ON direct_test
  FOR EACH STATEMENT EXECUTE PROCEDURE direct_statement_trigger();
EXPLAIN (COSTS OFF)
DELETE FROM direct_test;
BEGIN;
DELETE FROM direct_test;
SELECT * FROM direct_events ORDER BY event;
ROLLBACK;
DROP TRIGGER direct_before ON direct_test;
DROP TRIGGER direct_after ON direct_test;
DROP FUNCTION direct_statement_trigger();
DROP TABLE direct_events;

-- Assignment typmods and domains must be checked in PostgreSQL.
CREATE FOREIGN TABLE direct_short (id integer, val numeric(4,1), txt varchar(3))
  SERVER oracle OPTIONS (schema 'SCOTT', table 'DIRECT_TEST');
EXPLAIN (COSTS OFF)
UPDATE direct_short SET txt = txt || 'x';
EXPLAIN (COSTS OFF)
UPDATE direct_short SET val = val + 1;
BEGIN;
UPDATE direct_short SET txt = 'long' WHERE id = 1;
ROLLBACK;
CREATE DOMAIN direct_positive AS numeric CHECK (VALUE > 0);
EXPLAIN (COSTS OFF)
UPDATE direct_test SET val = (val - 100)::direct_positive;
BEGIN;
UPDATE direct_test SET val = (val - 100)::direct_positive WHERE id = 1;
ROLLBACK;
DROP FOREIGN TABLE direct_short;
DROP DOMAIN direct_positive;

-- PostgreSQL must evaluate source-column expressions and conversions.
SELECT oracle_execute('oracle', 'CREATE TABLE scott.direct_semantics (n NUMBER(20), d DATE, s VARCHAR2(100))');
SELECT oracle_execute('oracle', 'INSERT INTO scott.direct_semantics VALUES (2147483647, TO_DATE(''2026-10-28 15:30:00'', ''YYYY-MM-DD HH24:MI:SS''), ''a'' || CHR(0) || ''b'')');
CREATE FOREIGN TABLE direct_semantics (n integer, d date, s text OPTIONS (strip_zeros 'true'))
  SERVER oracle OPTIONS (schema 'SCOTT', table 'DIRECT_SEMANTICS');
CREATE FOREIGN TABLE direct_semantics_raw (n numeric, d timestamp, s_len integer)
  SERVER oracle OPTIONS (table '(SELECT n, d, LENGTH(s) AS s_len FROM SCOTT.DIRECT_SEMANTICS)');
EXPLAIN (COSTS OFF) UPDATE direct_semantics SET n = n + 1;
EXPLAIN (COSTS OFF) UPDATE direct_semantics SET d = d + 1;
EXPLAIN (COSTS OFF) UPDATE direct_semantics SET s = upper(s);
BEGIN;
UPDATE direct_semantics SET n = n + 1;
ROLLBACK;
BEGIN;
UPDATE direct_semantics SET d = d + 1, s = upper(s);
SELECT * FROM direct_semantics_raw;
ROLLBACK;
SELECT * FROM direct_semantics_raw;
DROP FOREIGN TABLE direct_semantics, direct_semantics_raw;
SELECT oracle_execute('oracle', 'DROP TABLE scott.direct_semantics PURGE');

ALTER FOREIGN TABLE direct_test OPTIONS (ADD readonly 'true');
DELETE FROM direct_test;
ALTER FOREIGN TABLE direct_test OPTIONS (SET readonly 'false');
SELECT * FROM direct_test ORDER BY id;
DROP FOREIGN TABLE direct_test;
SELECT oracle_execute('oracle', 'DROP TABLE scott.direct_test PURGE');
