/*
 * Tests with output that depends on the PostgreSQL or Oracle version.
 * Run after oracle_fdw and oracle_join, which set up the tables and statistics.
 *
 * Expected files (PostgreSQL / Oracle Server / Instant Client):
 * oracle_variants.out:   development / 19c / 19.32 (development plan format).
 * oracle_variants_0.out: 18 / XE 21.3 / 19.32 (CI).
 * oracle_variants_1.out: 18 / Free 23.26.3 / 23.26.3 (CI).
 * oracle_variants_0.out also matches 17 / 19c / 19.32.
 * pg_regress selects the matching expected file automatically.
 */

-- will fail with a read-only transaction
ALTER SERVER oracle OPTIONS (ADD isolation_level 'read_only');
SELECT oracle_close_connections();
DELETE FROM typetest1;

-- restore the default SERIALIZABLE isolation level
ALTER SERVER oracle OPTIONS (DROP isolation_level);
SELECT oracle_close_connections();

-- recover a savepoint after a remote constraint violation
BEGIN;
DELETE FROM shorty WHERE id = 2;
SAVEPOINT one;
-- will cause an error
INSERT INTO shorty (id, c) VALUES (1, 'c');
ROLLBACK TO one;
INSERT INTO typetest1 (id, c) VALUES (2, 'c');
ROLLBACK TO one;
SELECT id FROM shorty WHERE id = 1;
COMMIT;

-- array expression with an InitPlan
EXPLAIN (COSTS off) SELECT id FROM typetest1 WHERE vc = ANY (ARRAY['short', (SELECT 'varlena'::varchar)]) ORDER BY id;

-- use the same planner settings as oracle_join
SET enable_mergejoin = off;
-- inner rel is false, not pushed down
EXPLAIN (COSTS off)
SELECT 1 FROM (SELECT 1 FROM typetest1  WHERE false) AS subq1 RIGHT JOIN typetest1  AS ref1 ON NULL ORDER BY ref1.id;
-- semi-join, not pushed down
EXPLAIN (COSTS off)
SELECT t1.id FROM typetest1  t1 WHERE EXISTS (SELECT 1 FROM typetest1  t2 WHERE t1.d = t2.d) ORDER BY t1.id;
