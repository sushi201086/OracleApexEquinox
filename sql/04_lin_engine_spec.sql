--------------------------------------------------------------------------------
-- 04_lin_engine_spec.sql
-- LIN_ENGINE : Book_Jobs lineage engine.
--
--   1. Snapshot BOOK_JOBS into LIN_JOB, flag inactive rows (DISABLED_FLAG).
--   2. Explode JOB_NAMES ('ALL|Daily Load|Reset Pull') into LIN_JOB_GROUP.
--   3. Case A (no SQL_STMT): SOURCE_OBJECT -> TARGET_OBJECT edge.
--      Case B (SQL_STMT)   : parse SQL with LIN_SQL_PARSER, edges from every
--                            source to every target; fall back to metadata
--                            when the parse fails.
--   4. Capture DDL of every view in the graph (recursively upstream) from
--      ALL_VIEWS, parse it and add VIEW_DEF edges + column lineage.
--      ALL_DEPENDENCIES fills any reference the parser could not see.
--   5. Classify nodes (ROOT / INTERMEDIATE / TERMINAL), compute DAG levels
--      on the SCC-condensed graph, derive job -> job dependencies.
--------------------------------------------------------------------------------
set define off
-- AUTHID CURRENT_USER: dictionary views (ALL_VIEWS, ALL_TAB_COLUMNS,
-- ALL_DEPENDENCIES) then see objects granted to the caller through roles.
-- Run it as the schema that owns the LIN_* tables.
create or replace package lin_engine authid current_user as

  type t_trace_row is record (
    lvl            number,
    target_object  varchar2(261),
    target_column  varchar2(128),
    expression     varchar2(4000),
    transform_type varchar2(20),
    source_object  varchar2(261),
    source_column  varchar2(128),
    ref_role       varchar2(20),
    lineage_origin varchar2(20),
    job_num        number,
    path           varchar2(4000)
  );
  type t_trace_tab is table of t_trace_row;

  type t_obj_trace_row is record (
    lvl          number,
    source_node  varchar2(261),
    target_node  varchar2(261),
    job_num      number,
    job_names    varchar2(4000),
    action_type  varchar2(30),
    edge_origin  varchar2(20),
    ref_context  varchar2(10),
    path         varchar2(4000)
  );
  type t_obj_trace_tab is table of t_obj_trace_row;

  -- Run the whole engine; returns the new RUN_ID.
  function run (
    p_source_table     in varchar2 default 'BOOK_JOBS',
    p_owner            in varchar2 default null,     -- schema owning the ETL objects (default: current schema)
    p_run_label        in varchar2 default null,
    p_capture_views    in boolean  default true,     -- read ALL_VIEWS and parse view definitions
    p_view_depth       in pls_integer default 25,    -- how many view layers to walk upstream
    p_use_dependencies in boolean  default true,     -- complement view parsing with ALL_DEPENDENCIES
    p_save_ast         in boolean  default true      -- store the syntax trees in LIN_AST_NODE
  ) return number;

  procedure run (
    p_source_table     in varchar2 default 'BOOK_JOBS',
    p_owner            in varchar2 default null,
    p_run_label        in varchar2 default null,
    p_capture_views    in boolean  default true,
    p_view_depth       in pls_integer default 25,
    p_use_dependencies in boolean  default true,
    p_save_ast         in boolean  default true
  );

  -- 'Y' when a DISABLED_FLAG value means the job is inactive (Y, YES, D, DELETED, ...)
  function is_disabled (p_flag in varchar2) return varchar2 deterministic;

  -- Column lineage walk.  p_direction = UPSTREAM (how is it calculated)
  --                                   / DOWNSTREAM (where does it go)
  function trace_column (
    p_object    in varchar2,
    p_column    in varchar2,
    p_direction in varchar2 default 'UPSTREAM',
    p_run_id    in number   default null,
    p_max_depth in pls_integer default 30
  ) return t_trace_tab pipelined;

  -- Object lineage walk over LIN_EDGE
  function trace_object (
    p_object    in varchar2,
    p_direction in varchar2 default 'UPSTREAM',
    p_run_id    in number   default null,
    p_max_depth in pls_integer default 50
  ) return t_obj_trace_tab pipelined;

  -- Full CREATE VIEW DDL through DBMS_METADATA
  function view_ddl (p_view in varchar2, p_owner in varchar2 default null) return clob;

  procedure print_summary (p_run_id in number default null);

end lin_engine;
/
