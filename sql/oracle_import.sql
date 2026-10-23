SET client_min_messages = WARNING;

CREATE SCHEMA import;

/* first, import only a table and a materialized view */
IMPORT FOREIGN SCHEMA "SCOTT"
   LIMIT TO ("typetest1", ttv, mattest2)
   FROM SERVER oracle
   INTO import
   OPTIONS (case 'lower', collation 'C', skip_views 'true');

SELECT t.relname, fs.srvname, ft.ftoptions
FROM pg_foreign_table ft
     JOIN pg_class t ON ft.ftrelid = t.oid
     JOIN pg_foreign_server fs ON ft.ftserver = fs.oid
WHERE relnamespace = 'import'::regnamespace
ORDER BY t.relname;

/* then import only a view */
IMPORT FOREIGN SCHEMA "SCOTT"
   LIMIT TO ("typetest1", ttv, mattest2)
   FROM SERVER oracle
   INTO import
   OPTIONS (case 'lower', skip_tables 'true', skip_matviews 'true');

SELECT t.relname, fs.srvname, ft.ftoptions
FROM pg_foreign_table ft
     JOIN pg_class t ON ft.ftrelid = t.oid
     JOIN pg_foreign_server fs ON ft.ftserver = fs.oid
WHERE relnamespace = 'import'::regnamespace
ORDER BY t.relname;

SELECT t.relname, a.attname, a.atttypid::regtype, a.attfdwoptions
FROM pg_attribute AS a
   JOIN pg_class AS t ON t.oid = a.attrelid
WHERE t.relname IN ('typetest1', 'ttv', 'mattest2')
  AND a.attnum > 0
  AND t.relnamespace = 'import'::regnamespace
  AND NOT a.attisdropped
ORDER BY t.relname, a.attnum;

-- Imported IOTs retain their organization and omit legacy key options.
ALTER SERVER oracle OPTIONS (ADD isolation_level 'read_committed');
SELECT oracle_close_connections();
DO $$
BEGIN
   PERFORM oracle_execute('oracle', $oracle$
      BEGIN
         EXECUTE IMMEDIATE 'DROP TABLE SCOTT.FDW_IMPORT_IOT PURGE';
      EXCEPTION
         WHEN OTHERS THEN
            IF SQLCODE != -942 THEN
               RAISE;
            END IF;
      END;
   $oracle$);
   PERFORM oracle_execute('oracle', $oracle$
      CREATE TABLE SCOTT.FDW_IMPORT_IOT (
         id VARCHAR2(3000) PRIMARY KEY, note NUMBER
      ) ORGANIZATION INDEX
   $oracle$);
   PERFORM oracle_execute('oracle', $oracle$
      INSERT INTO SCOTT.FDW_IMPORT_IOT VALUES (rpad('a', 3000, 'a'), 1)
   $oracle$);
END;
$$;
ALTER SERVER oracle OPTIONS (DROP isolation_level);
SELECT oracle_close_connections();

IMPORT FOREIGN SCHEMA "SCOTT" LIMIT TO (fdw_import_iot)
   FROM SERVER oracle INTO import OPTIONS (case 'lower');
SELECT ftoptions FROM pg_foreign_table
WHERE ftrelid = 'import.fdw_import_iot'::regclass;
SELECT attname, attfdwoptions FROM pg_attribute
WHERE attrelid = 'import.fdw_import_iot'::regclass AND attnum > 0
ORDER BY attnum;
SELECT length(id) AS key_length, note FROM import.fdw_import_iot;

-- An imported long-key IOT can be modified using its logical ROWID.
BEGIN;
UPDATE import.fdw_import_iot SET id = 'changed', note = note + 1
   RETURNING id, note;
DELETE FROM import.fdw_import_iot WHERE id = 'changed' RETURNING id, note;
ROLLBACK;

DROP FOREIGN TABLE import.fdw_import_iot;
DO $$
BEGIN
   PERFORM oracle_execute('oracle', 'DROP TABLE SCOTT.FDW_IMPORT_IOT PURGE');
END;
$$;
