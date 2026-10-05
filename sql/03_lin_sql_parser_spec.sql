--------------------------------------------------------------------------------
-- 03_lin_sql_parser_spec.sql
-- LIN_SQL_PARSER : a fault-tolerant SQL "tree sitter" written in PL/SQL.
--
--   * Tokenizer   : Oracle SQL / PL-SQL lexer (quoted ids, q'[...]' strings,
--                   comments/hints, binds, multi-char operators).
--   * Parser      : recursive descent, builds a concrete syntax tree
--                   (node, parent, char range, text) like tree-sitter does.
--                   Unknown constructs never abort the parse; they are kept
--                   as generic nodes and the status becomes PARTIAL.
--   * Extraction  : object references (sources / targets, DATA vs FILTER)
--                   and column-level lineage (target column <- source
--                   column + expression + transform type), resolving
--                   aliases, CTEs, inline views, set operators, SELECT *.
--------------------------------------------------------------------------------
set define off
create or replace package lin_sql_parser as

  ------------------------------------------------------------------------------
  -- Result types
  ------------------------------------------------------------------------------
  type t_obj_ref is record (
    object_name   varchar2(261),
    object_role   varchar2(10),    -- SOURCE / TARGET / CALL
    ref_context   varchar2(10)     -- DATA / FILTER
  );
  type t_obj_refs is table of t_obj_ref index by pls_integer;

  type t_col_lin is record (
    target_column  varchar2(128),
    column_pos     number,
    expression     varchar2(4000),
    transform_type varchar2(20),
    source_object  varchar2(261),
    source_column  varchar2(128),
    ref_role       varchar2(20),
    resolution     varchar2(30)
  );
  type t_col_lins is table of t_col_lin index by pls_integer;

  type t_ast_row is record (
    node_id      number,
    parent_id    number,
    node_type    varchar2(30),
    node_name    varchar2(4000),
    node_text    varchar2(4000),
    start_pos    number,
    end_pos      number,
    depth        number,
    sibling_seq  number
  );
  type t_ast_tab is table of t_ast_row;

  type t_token_row is record (
    token_no   number,
    token_type varchar2(8),
    token_text varchar2(4000),
    start_pos  number,
    end_pos    number
  );
  type t_token_tab is table of t_token_row;

  ------------------------------------------------------------------------------
  -- Parse a statement. Results are kept in package state until the next call.
  --   p_target_hint : object being defined (view name) when p_sql is only the
  --                   SELECT text of a view (ALL_VIEWS.TEXT)
  --   p_owner       : schema used for dictionary look-ups (SELECT * expansion,
  --                   unqualified column resolution, positional INSERT mapping)
  --   p_use_dict    : allow dictionary look-ups (ALL_TAB_COLUMNS)
  -- Returns status OK / PARTIAL / FAILED.
  ------------------------------------------------------------------------------
  function parse (
    p_sql          in clob,
    p_target_hint  in varchar2 default null,
    p_owner        in varchar2 default null,
    p_use_dict     in boolean  default true
  ) return varchar2;

  function status        return varchar2;
  function message       return varchar2;
  function stmt_type     return varchar2;   -- SELECT/INSERT/UPDATE/DELETE/MERGE/PLSQL/CREATE_VIEW/TRUNCATE/UNKNOWN
  function target_object return varchar2;   -- first target (INSERT/UPDATE/DELETE/MERGE/CREATE VIEW)
  function token_count   return pls_integer;
  function obj_refs      return t_obj_refs;
  function col_lineage   return t_col_lins;
  function ast           return t_ast_tab;

  -- Persist the last parse into LIN_PARSE / LIN_AST_NODE / LIN_COLUMN_LINEAGE.
  -- Returns the new PARSE_ID.
  function save (
    p_run_id         in number,
    p_source_kind    in varchar2,
    p_job_num        in number   default null,
    p_object_name    in varchar2 default null,
    p_lineage_origin in varchar2 default null,   -- null = do not store column lineage
    p_save_ast       in boolean  default true
  ) return number;

  ------------------------------------------------------------------------------
  -- Ad-hoc helpers usable from SQL:
  --   select * from table(lin_sql_parser.parse_tree('select a+b x from t'));
  --   select * from table(lin_sql_parser.tokens('select 1 from dual'));
  ------------------------------------------------------------------------------
  function parse_tree (p_sql in clob, p_owner in varchar2 default null) return t_ast_tab pipelined;
  function tokens     (p_sql in clob) return t_token_tab pipelined;

  -- Forget cached dictionary column lists
  procedure clear_cache;

  -- Normalise an identifier chain the way the engine stores node names
  function norm_name (p_name in varchar2) return varchar2;

end lin_sql_parser;
/
