--------------------------------------------------------------------------------
-- 01_lineage_schema.sql
-- Book_Jobs lineage repository: tables, sequences and helper views.
--
-- All lineage tables are keyed by RUN_ID so that every execution of
-- LIN_ENGINE.RUN keeps its own snapshot (history / diff between runs).
--
-- Re-runnable: drops existing objects first (errors ignored).
--------------------------------------------------------------------------------
set define off

declare
  procedure drop_if_exists(p_stmt varchar2) is
  begin
    execute immediate p_stmt;
  exception
    when others then
      if sqlcode not in (-942, -2289, -4043, -1418) then raise; end if;
  end;
begin
  for t in (select column_value tname from table(sys.odcivarchar2list(
              'LIN_COLUMN_LINEAGE','LIN_AST_NODE','LIN_PARSE','LIN_VIEW_DDL',
              'LIN_JOB_DEP','LIN_EDGE','LIN_NODE','LIN_JOB_OBJECT',
              'LIN_JOB_GROUP','LIN_JOB','LIN_RUN')))
  loop
    drop_if_exists('drop table ' || t.tname || ' cascade constraints purge');
  end loop;
  drop_if_exists('drop sequence LIN_RUN_SEQ');
  drop_if_exists('drop sequence LIN_PARSE_SEQ');
  drop_if_exists('drop sequence LIN_EDGE_SEQ');
end;
/

create sequence lin_run_seq   nocache;
create sequence lin_parse_seq cache 100;
create sequence lin_edge_seq  cache 100;

--------------------------------------------------------------------------------
-- One row per engine execution
--------------------------------------------------------------------------------
create table lin_run (
  run_id            number         not null,
  run_label         varchar2(200),
  source_table      varchar2(261)  not null,
  object_owner      varchar2(128)  not null,
  started_at        timestamp      default systimestamp not null,
  finished_at       timestamp,
  status            varchar2(20)   default 'RUNNING' not null,  -- RUNNING / COMPLETED / FAILED
  rows_read         number,
  rows_active       number,
  rows_disabled     number,
  sql_parsed        number,
  sql_fallback      number,
  views_captured    number,
  edge_count        number,
  node_count        number,
  message           varchar2(4000),
  constraint lin_run_pk primary key (run_id)
);

--------------------------------------------------------------------------------
-- Snapshot of every Book_Jobs row + derived classification
--------------------------------------------------------------------------------
create table lin_job (
  run_id            number         not null,
  job_num           number         not null,
  job_names         varchar2(4000),
  target_object     varchar2(4000),
  source_object     varchar2(4000),
  unique_col        varchar2(4000),
  filter_clause     varchar2(4000),
  sql_stmt          clob,
  disabled_flag     varchar2(30),
  is_active         char(1)        not null,      -- Y / N  (business rule 1)
  case_type         varchar2(20),                 -- A_STANDARD / B_SQL
  action_type       varchar2(30),                 -- LOAD_REPLACE / LOAD_APPEND / LOAD_KEYED / INSERT_SELECT /
                                                  -- INSERT_VALUES / UPDATE / DELETE / MERGE / TRUNCATE / PLSQL_CALL / UNKNOWN
  load_key          varchar2(4000),               -- UNIQUE_COL when it is a key (not APPEND)
  parse_id          number,
  parse_status      varchar2(20),                 -- N_A / OK / PARTIAL / FALLBACK
  parse_message     varchar2(4000),
  exec_seq          number,                       -- execution order (row order of JOB_NUM)
  constraint lin_job_pk primary key (run_id, job_num),
  constraint lin_job_run_fk foreign key (run_id) references lin_run(run_id) on delete cascade
);

--------------------------------------------------------------------------------
-- JOB_NAMES exploded: 'ALL|Daily Load|Reset Pull' -> 3 rows (business rule 3)
--------------------------------------------------------------------------------
create table lin_job_group (
  run_id            number         not null,
  job_num           number         not null,
  group_name        varchar2(200)  not null,
  group_pos         number         not null,      -- 1-based position in the pipe path
  group_path        varchar2(4000),               -- path up to and including this group
  constraint lin_job_group_pk primary key (run_id, job_num, group_pos),
  constraint lin_job_group_fk foreign key (run_id, job_num) references lin_job(run_id, job_num) on delete cascade
);
create index lin_job_group_i1 on lin_job_group(run_id, group_name);

--------------------------------------------------------------------------------
-- Objects read / written by each job (from metadata or parsed SQL)
--------------------------------------------------------------------------------
create table lin_job_object (
  run_id            number         not null,
  job_num           number         not null,
  object_name       varchar2(261)  not null,
  object_role       varchar2(10)   not null,      -- SOURCE / TARGET / CALL
  ref_context       varchar2(10)   not null,      -- DATA / FILTER
  derived_from      varchar2(20)   not null,      -- METADATA / SQL_PARSE / FALLBACK
  constraint lin_job_object_pk primary key (run_id, job_num, object_name, object_role, ref_context),
  constraint lin_job_object_fk foreign key (run_id, job_num) references lin_job(run_id, job_num) on delete cascade
);
create index lin_job_object_i1 on lin_job_object(run_id, object_name, object_role);

--------------------------------------------------------------------------------
-- Graph edges  SOURCE_NODE -> TARGET_NODE   (business rule 4: DAG, multi-parent)
--------------------------------------------------------------------------------
create table lin_edge (
  run_id            number         not null,
  edge_id           number         not null,
  source_node       varchar2(261)  not null,
  target_node       varchar2(261)  not null,
  job_num           number,                       -- null for view-definition edges
  job_names         varchar2(4000),
  action_type       varchar2(30),
  edge_origin       varchar2(20)   not null,      -- JOB_STANDARD / JOB_SQL / JOB_FALLBACK / JOB_PLSQL / VIEW_DEF / DB_DEPENDENCY
  ref_context       varchar2(10)   default 'DATA' not null,  -- DATA / FILTER
  is_self_loop      char(1)        default 'N' not null,
  constraint lin_edge_pk primary key (run_id, edge_id),
  constraint lin_edge_run_fk foreign key (run_id) references lin_run(run_id) on delete cascade
);
create index lin_edge_i1 on lin_edge(run_id, source_node);
create index lin_edge_i2 on lin_edge(run_id, target_node);

--------------------------------------------------------------------------------
-- Graph nodes with classification
--------------------------------------------------------------------------------
create table lin_node (
  run_id            number         not null,
  node_name         varchar2(261)  not null,
  node_type         varchar2(30),                 -- TABLE / VIEW / MATERIALIZED VIEW / SYNONYM / PROCEDURE / PSEUDO / UNKNOWN
  type_source       varchar2(20),                 -- DICTIONARY / HEURISTIC
  node_class        varchar2(20),                 -- ROOT / INTERMEDIATE / TERMINAL / ISOLATED (full graph incl. view defs)
  job_node_class    varchar2(20),                 -- same, using job edges only
  in_degree         number,
  out_degree        number,
  job_in_degree     number,
  job_out_degree    number,
  dag_level         number,                       -- longest path from a root (null when in a cycle)
  in_cycle          char(1)        default 'N',
  writer_jobs       number,                       -- # active jobs writing this object
  reader_jobs       number,                       -- # active jobs reading this object
  first_writer_job  number,
  last_writer_job   number,
  view_captured     char(1)        default 'N',
  constraint lin_node_pk primary key (run_id, node_name),
  constraint lin_node_run_fk foreign key (run_id) references lin_run(run_id) on delete cascade
);

--------------------------------------------------------------------------------
-- Job -> job dependencies (resolved through views; "Table 1 feeds Job 5")
--------------------------------------------------------------------------------
create table lin_job_dep (
  run_id            number         not null,
  job_num           number         not null,      -- consumer job
  depends_on_job    number         not null,      -- producer job
  via_object        varchar2(261)  not null,      -- object written by producer
  read_object       varchar2(261)  not null,      -- object read by consumer (may be a view on top of via_object)
  hops              number         not null,      -- 0 = direct read, n = through n view layers
  dep_type          varchar2(20)   not null,      -- PRIOR_STEP (producer runs earlier) / PRIOR_CYCLE (producer runs later => previous run's data)
  is_latest_writer  char(1)        not null,      -- producer is the last writer of via_object before the consumer
  same_group        char(1)        not null,      -- producer and consumer share a job group
  constraint lin_job_dep_pk primary key (run_id, job_num, depends_on_job, via_object, read_object),
  constraint lin_job_dep_run_fk foreign key (run_id) references lin_run(run_id) on delete cascade
);

--------------------------------------------------------------------------------
-- View DDL extracted from the data dictionary
--------------------------------------------------------------------------------
create table lin_view_ddl (
  run_id            number         not null,
  owner             varchar2(128)  not null,
  view_name         varchar2(128)  not null,
  view_text         clob,
  text_length       number,
  capture_level     number,                       -- 0 = referenced by a job, n = discovered n levels upstream
  parse_id          number,
  captured_at       timestamp      default systimestamp,
  constraint lin_view_ddl_pk primary key (run_id, owner, view_name),
  constraint lin_view_ddl_run_fk foreign key (run_id) references lin_run(run_id) on delete cascade
);

--------------------------------------------------------------------------------
-- One row per parsed SQL text (job SQL_STMT or view definition)
--------------------------------------------------------------------------------
create table lin_parse (
  parse_id          number         not null,
  run_id            number         not null,
  source_kind       varchar2(10)   not null,      -- JOB_SQL / VIEW / ADHOC
  job_num           number,
  object_name       varchar2(261),                -- view name for VIEW, target for JOB_SQL
  stmt_type         varchar2(20),                 -- SELECT / INSERT / UPDATE / DELETE / MERGE / PLSQL / CREATE_VIEW / TRUNCATE / UNKNOWN
  status            varchar2(20),                 -- OK / PARTIAL / FAILED
  message           varchar2(4000),
  token_count       number,
  ast_node_count    number,
  sql_text          clob,
  parsed_at         timestamp      default systimestamp,
  constraint lin_parse_pk primary key (parse_id),
  constraint lin_parse_run_fk foreign key (run_id) references lin_run(run_id) on delete cascade
);
create index lin_parse_i1 on lin_parse(run_id, object_name);

--------------------------------------------------------------------------------
-- Concrete syntax tree (tree-sitter style: node, parent, byte range, text)
--------------------------------------------------------------------------------
create table lin_ast_node (
  parse_id          number         not null,
  node_id           number         not null,
  parent_id         number,
  node_type         varchar2(30)   not null,      -- STATEMENT, QUERY, SELECT, SELECT_LIST, SELECT_ITEM, EXPR, COLUMN_REF,
                                                  -- FUNCTION, CASE, WINDOW, SUBQUERY, FROM, TABLE_REF, CTE_REF, DERIVED_TABLE,
                                                  -- JOIN, WHERE, GROUP_BY, HAVING, ORDER_BY, WITH, CTE, SET_OP, INSERT, UPDATE,
                                                  -- SET_ITEM, DELETE, MERGE, VALUES, LITERAL, OPERATOR, CALL ...
  node_name         varchar2(4000),               -- identifier / alias / function name / operator
  node_text         varchar2(4000),               -- source text covered by the node (truncated to 4000)
  start_pos         number,                       -- 1-based char offset in LIN_PARSE.SQL_TEXT
  end_pos           number,
  depth             number,
  sibling_seq       number,
  constraint lin_ast_node_pk primary key (parse_id, node_id),
  constraint lin_ast_node_fk foreign key (parse_id) references lin_parse(parse_id) on delete cascade
);
create index lin_ast_node_i1 on lin_ast_node(parse_id, parent_id);

--------------------------------------------------------------------------------
-- Column-level lineage: how every target column is calculated
--------------------------------------------------------------------------------
create table lin_column_lineage (
  run_id            number         not null,
  parse_id          number,                       -- null for metadata (standard load) lineage
  lineage_origin    varchar2(20)   not null,      -- VIEW_DEF / JOB_SQL / JOB_STANDARD
  job_num           number,
  target_object     varchar2(261)  not null,
  target_column     varchar2(128)  not null,      -- '*' when not expandable without dictionary
  column_pos        number,
  expression        varchar2(4000),               -- expression text producing the target column
  transform_type    varchar2(20),                 -- DIRECT / RENAME / CALCULATED / CASE / AGGREGATE / WINDOW / CONSTANT / STAR
  source_object     varchar2(261),
  source_column     varchar2(128),
  ref_role          varchar2(20),                 -- VALUE / CONDITION / WINDOW / KEY
  resolution        varchar2(30),                 -- RESOLVED / AMBIGUOUS / UNRESOLVED / DICTIONARY
  constraint lin_col_lin_run_fk foreign key (run_id) references lin_run(run_id) on delete cascade
);
create index lin_column_lineage_i1 on lin_column_lineage(run_id, target_object, target_column);
create index lin_column_lineage_i2 on lin_column_lineage(run_id, source_object, source_column);

--------------------------------------------------------------------------------
-- Convenience views (always on the latest completed run)
--------------------------------------------------------------------------------
create or replace view lin_v_latest_run as
select max(run_id) run_id from lin_run where status = 'COMPLETED';

create or replace view lin_v_edges as
select e.* from lin_edge e join lin_v_latest_run r on r.run_id = e.run_id;

create or replace view lin_v_nodes as
select n.* from lin_node n join lin_v_latest_run r on r.run_id = n.run_id;

create or replace view lin_v_group_edges as
select g.group_name, g.group_pos, e.*
from   lin_edge e
join   lin_job_group g on g.run_id = e.run_id and g.job_num = e.job_num
join   lin_v_latest_run r on r.run_id = e.run_id;

-- Per job-group roots / terminals inside the group's own sub-graph
create or replace view lin_v_group_node_class as
with ge as (
  select distinct group_name, source_node, target_node
  from   lin_v_group_edges
  where  is_self_loop = 'N'
), gn as (
  select group_name, source_node node_name, 1 is_src, 0 is_tgt from ge
  union all
  select group_name, target_node, 0, 1 from ge
)
select group_name, node_name,
       case when max(is_tgt) = 0 then 'ROOT'
            when max(is_src) = 0 then 'TERMINAL'
            else 'INTERMEDIATE' end group_node_class
from   gn
group  by group_name, node_name;

create or replace view lin_v_column_lineage as
select c.* from lin_column_lineage c join lin_v_latest_run r on r.run_id = c.run_id;
