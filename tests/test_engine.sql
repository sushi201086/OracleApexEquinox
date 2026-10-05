--------------------------------------------------------------------------------
-- tests/test_engine.sql
-- Self-checking test: loads the Book_Jobs sheet, builds the mock schema, runs
-- the engine and asserts the expected lineage. Raises ORA-20999 on failure.
--
--   sqlplus user/pwd@db @tests/test_engine.sql      (from the repository root)
--------------------------------------------------------------------------------
set define off
set serveroutput on size unlimited
whenever sqlerror exit failure rollback

@data/output/book_jobs_load.sql
@tests/mock_schema.sql

declare
  l_run   number;
  l_fail  pls_integer := 0;
  l_n     number;
  l_s     varchar2(4000);

  procedure check_eq (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    if nvl(p_got, '~') = nvl(p_exp, '~') then
      dbms_output.put_line('PASS  ' || p_name);
    else
      dbms_output.put_line('FAIL  ' || p_name || ': got [' || p_got || '] expected [' || p_exp || ']');
      l_fail := l_fail + 1;
    end if;
  end check_eq;

  function q (p_sql varchar2) return varchar2 is
    l varchar2(4000);
  begin
    execute immediate p_sql into l;
    return l;
  exception
    when no_data_found then return null;
    when too_many_rows then return 'TOO_MANY_ROWS';
  end q;
begin
  l_run := lin_engine.run(p_run_label => 'test_engine.sql');

  -- business rule 1: inactive rows
  check_eq('jobs read',      q('select count(*) from lin_job where run_id = ' || l_run), '406');
  check_eq('jobs disabled',  q('select count(*) from lin_job where run_id = ' || l_run || ' and is_active = ''N'''), '31');
  check_eq('no edge from a disabled job',
           q('select count(*) from lin_edge e join lin_job j on j.run_id = e.run_id and j.job_num = e.job_num
              where e.run_id = ' || l_run || ' and j.is_active = ''N'''), '0');

  -- business rule 2: case A / case B
  check_eq('case A jobs', q('select count(*) from lin_job where run_id = ' || l_run || ' and case_type = ''A_STANDARD'''), '280');
  check_eq('case B jobs', q('select count(*) from lin_job where run_id = ' || l_run || ' and case_type = ''B_SQL'''), '95');
  check_eq('no parse fallback', q('select count(*) from lin_job where run_id = ' || l_run || ' and parse_status = ''FALLBACK'''), '0');
  check_eq('job 125 INSERT SELECT edge',
           q('select action_type || '':'' || edge_origin from lin_edge where run_id = ' || l_run ||
             ' and job_num = 125 and source_node = ''APP_SNAP_BKG_V'' and target_node = ''SNAP_BKG'''),
           'INSERT_SELECT:JOB_SQL');
  check_eq('job 124 DELETE filter edge',
           q('select ref_context from lin_edge where run_id = ' || l_run ||
             ' and job_num = 124 and source_node = ''LKP_A_PULL_VAR'' and target_node = ''SNAP_BKG'''), 'FILTER');
  check_eq('job 39 UPDATE reads STG_SCD_CON_S5',
           q('select count(*) from lin_edge where run_id = ' || l_run ||
             ' and job_num = 39 and source_node = ''STG_SCD_CON_S5'' and target_node = ''SCD_CON_DTL'''), '2');
  check_eq('job 230 PL/SQL call edge',
           q('select edge_origin from lin_edge where run_id = ' || l_run ||
             ' and job_num = 230 and source_node = ''CON_DL.SEND_CON_UPDATES'''), 'JOB_PLSQL');
  check_eq('procedure node type',
           q('select node_type from lin_node where run_id = ' || l_run || ' and node_name = ''CON_DL.SEND_CON_UPDATES'''), 'PROCEDURE');
  check_eq('pseudo node type',
           q('select node_type from lin_node where run_id = ' || l_run || ' and node_name = ''STATUS EMAIL'''), 'PSEUDO');

  -- business rule 3: job group hierarchy
  check_eq('distinct groups', q('select count(distinct group_name) from lin_job_group where run_id = ' || l_run), '27');
  check_eq('group path of job 12',
           q('select group_path from lin_job_group where run_id = ' || l_run || ' and job_num = 12 and group_pos = 3'),
           'ALL|Daily Load|Reset Pull');

  -- view capture + business rule 4 (skipped connections through views)
  check_eq('views captured', q('select count(*) from lin_view_ddl where run_id = ' || l_run), '7');
  check_eq('upstream view discovered (level 1)',
           q('select capture_level from lin_view_ddl where run_id = ' || l_run || ' and view_name = ''BKG_BASE_V'''), '1');
  check_eq('job 125 depends on job 54 through 2 view layers',
           q('select hops || '':'' || dep_type || '':'' || is_latest_writer from lin_job_dep where run_id = ' || l_run ||
             ' and job_num = 125 and depends_on_job = 54'), '2:PRIOR_STEP:Y');
  check_eq('SCD cycle detected',
           q('select count(*) from lin_node where run_id = ' || l_run || ' and in_cycle = ''Y'''), '4');
  check_eq('source table is ROOT',
           q('select node_class from lin_node where run_id = ' || l_run || ' and node_name = ''SRC_FX_RATE'''), 'ROOT');
  check_eq('report table is TERMINAL',
           q('select node_class from lin_node where run_id = ' || l_run || ' and node_name = ''RPT_DAILY_LIST_1C'''), 'TERMINAL');

  -- column lineage
  check_eq('aggregate column',
           q('select transform_type || '':'' || source_object || ''.'' || source_column from lin_column_lineage where run_id = ' || l_run ||
             ' and target_object = ''APP_SNAP_BKG_V'' and target_column = ''TCV_USD'''), 'AGGREGATE:BKG_BASE_V.AMT_USD');
  check_eq('calculated column has 2 inputs',
           q('select count(*) from lin_column_lineage where run_id = ' || l_run ||
             ' and target_object = ''STG_SCD_CON_S5_V'' and target_column = ''AMT_USD'''), '2');
  check_eq('CASE condition role',
           q('select count(*) from lin_column_lineage where run_id = ' || l_run ||
             ' and target_object = ''STG_SCD_CON_S5_V'' and target_column = ''CHANGE_TYPE'' and ref_role = ''CONDITION'''), '4');
  check_eq('UPDATE SET lineage',
           q('select transform_type || '':'' || source_object || ''.'' || source_column from lin_column_lineage where run_id = ' || l_run ||
             ' and job_num = 39 and target_column = ''DTL_SNAP_END_DATE'''), 'AGGREGATE:STG_SCD_CON_S5.DTL_SNAP_DATE');
  check_eq('SELECT * expanded through dictionary',
           q('select count(*) from lin_column_lineage where run_id = ' || l_run ||
             ' and job_num = 125 and resolution = ''DICTIONARY'''), '8');
  check_eq('standard load lineage by column name',
           q('select count(*) from lin_column_lineage where run_id = ' || l_run ||
             ' and job_num = 35 and lineage_origin = ''JOB_STANDARD'''), '8');

  select count(*), max(path) into l_n, l_s
  from   table(lin_engine.trace_column('RPT_DAILY_LIST_1C', 'TCV_USD', 'UPSTREAM', l_run))
  where  source_object = 'SRC_FX_RATE';
  check_eq('upstream trace reaches SRC_FX_RATE.RATE', to_char(l_n), '1');
  dbms_output.put_line('      ' || l_s);

  select count(*) into l_n
  from   table(lin_engine.trace_column('SRC_FX_RATE', 'RATE', 'DOWNSTREAM', l_run))
  where  target_object = 'RPT_DAILY_LIST_1C' and target_column = 'TCV_USD';
  check_eq('downstream trace reaches RPT_DAILY_LIST_1C.TCV_USD', to_char(l_n), '2');

  -- syntax tree
  check_eq('AST stored for view',
           q('select count(*) from lin_ast_node a join lin_parse p on p.parse_id = a.parse_id where p.run_id = ' || l_run ||
             ' and p.object_name = ''APP_SNAP_BKG_V'' and a.node_type = ''WINDOW'''), '1');
  check_eq('all views parsed OK',
           q('select count(*) from lin_parse where run_id = ' || l_run || ' and source_kind = ''VIEW'' and status != ''OK'''), '0');

  if l_fail > 0 then
    raise_application_error(-20999, l_fail || ' lineage test(s) failed');
  end if;
  dbms_output.put_line('All lineage tests passed (run ' || l_run || ').');
end;
/
