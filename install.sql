--------------------------------------------------------------------------------
-- install.sql  -  installs the Book_Jobs lineage engine in the current schema
--
--   sqlplus user/pwd@db @install.sql
--   sql     user/pwd@db @install.sql            (SQLcl)
--
-- Then load BOOK_JOBS (data/output/book_jobs_load.sql or LOAD_BOOK_JOBS_XLSX)
-- and run:   exec lin_engine.run
--------------------------------------------------------------------------------
set define off
set serveroutput on size unlimited
whenever sqlerror exit failure rollback

prompt == lineage repository tables
@@sql/01_lineage_schema.sql

prompt == BOOK_JOBS table + xlsx loader
@@sql/02_book_jobs_table.sql

prompt == LIN_SQL_PARSER (SQL tree sitter)
@@sql/03_lin_sql_parser_spec.sql
@@sql/03_lin_sql_parser_body.sql

prompt == LIN_ENGINE
@@sql/04_lin_engine_spec.sql
@@sql/04_lin_engine_body.sql

whenever sqlerror continue
prompt == invalid objects (expect none)
select object_name, object_type from user_objects
where  status = 'INVALID' and (object_name like 'LIN%' or object_name in ('LOAD_BOOK_JOBS_XLSX'));
