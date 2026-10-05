--------------------------------------------------------------------------------
-- 06_lineage_reports.sql
-- Ready-made questions against the lineage repository (latest completed run).
-- Substitution variables are not used: edit the literals in the WHERE clauses.
--------------------------------------------------------------------------------
set define off
set linesize 250 pagesize 500

--------------------------------------------------------------------------------
-- 1. Run overview
--------------------------------------------------------------------------------
select run_id, run_label, status, rows_read, rows_active, rows_disabled, sql_parsed,
       sql_fallback, views_captured, node_count, edge_count, started_at, finished_at
from   lin_run
order  by run_id desc;

--------------------------------------------------------------------------------
-- 2. Root / intermediate / terminal nodes
--    NODE_CLASS     : full graph (jobs + view definitions)
--    JOB_NODE_CLASS : job edges only (VIEW_ONLY = only reached through views)
--------------------------------------------------------------------------------
select node_class, node_type, count(*) nodes
from   lin_v_nodes
group  by node_class, node_type
order  by node_class, node_type;

-- true source systems (nothing upstream)
select node_name, node_type, type_source, out_degree, reader_jobs
from   lin_v_nodes
where  node_class = 'ROOT'
order  by out_degree desc, node_name;

-- final reporting tables / marts (nothing downstream)
select node_name, node_type, in_degree, writer_jobs, last_writer_job, dag_level
from   lin_v_nodes
where  node_class = 'TERMINAL'
order  by dag_level desc, node_name;

-- staging / transient objects
select node_name, node_type, in_degree, out_degree, writer_jobs, reader_jobs, dag_level, in_cycle
from   lin_v_nodes
where  node_class = 'INTERMEDIATE'
order  by dag_level, node_name;

-- objects participating in a cycle (e.g. SCD tables read by their own staging views)
select node_name, node_type, dag_level
from   lin_v_nodes
where  in_cycle = 'Y'
order  by dag_level, node_name;

--------------------------------------------------------------------------------
-- 3. Jobs
--------------------------------------------------------------------------------
-- action types and parse status of active jobs
select case_type, action_type, parse_status, count(*) jobs
from   lin_job
where  run_id = (select run_id from lin_v_latest_run) and is_active = 'Y'
group  by case_type, action_type, parse_status
order  by 1, 2, 3;

-- custom SQL that fell back to metadata or parsed only partially
select j.job_num, j.job_names, j.target_object, j.parse_status, j.parse_message,
       dbms_lob.substr(j.sql_stmt, 200, 1) sql_start
from   lin_job j
where  j.run_id = (select run_id from lin_v_latest_run)
and    j.parse_status in ('FALLBACK', 'PARTIAL')
order  by j.job_num;

-- inactive jobs (DISABLED_FLAG)
select job_num, job_names, target_object, source_object, disabled_flag
from   lin_job
where  run_id = (select run_id from lin_v_latest_run) and is_active = 'N'
order  by job_num;

--------------------------------------------------------------------------------
-- 4. Job groups (JOB_NAMES hierarchy)
--------------------------------------------------------------------------------
select g.group_name,
       count(distinct g.job_num)                                          jobs,
       count(distinct case when j.is_active = 'Y' then g.job_num end)     active_jobs,
       min(g.job_num) first_job, max(g.job_num) last_job
from   lin_job_group g
join   lin_job j on j.run_id = g.run_id and j.job_num = g.job_num
where  g.run_id = (select run_id from lin_v_latest_run)
group  by g.group_name
order  by g.group_name;

-- roots / terminals inside one group's sub-graph
select group_name, group_node_class, node_name
from   lin_v_group_node_class
where  group_name = 'Daily Load'
order  by group_node_class, node_name;

--------------------------------------------------------------------------------
-- 5. Job -> job dependencies (resolved through views)
--------------------------------------------------------------------------------
select d.job_num, c.target_object consumer_target, d.depends_on_job, p.target_object producer_target,
       d.via_object, d.read_object, d.hops, d.dep_type, d.is_latest_writer, d.same_group
from   lin_job_dep d
join   lin_job c on c.run_id = d.run_id and c.job_num = d.job_num
join   lin_job p on p.run_id = d.run_id and p.job_num = d.depends_on_job
where  d.run_id = (select run_id from lin_v_latest_run)
and    d.is_latest_writer = 'Y'
order  by d.job_num, d.depends_on_job;

-- dependencies that cross job groups (a group relying on another group's output)
select distinct d.job_num, d.depends_on_job, d.via_object
from   lin_job_dep d
where  d.run_id = (select run_id from lin_v_latest_run)
and    d.same_group = 'N' and d.dep_type = 'PRIOR_STEP'
order  by 1, 2;

--------------------------------------------------------------------------------
-- 6. Object lineage (impact analysis)
--------------------------------------------------------------------------------
-- everything upstream of a report table
select lvl, source_node, target_node, job_num, action_type, edge_origin, ref_context
from   table(lin_engine.trace_object('SNAP_BKG', 'UPSTREAM'));

-- everything that breaks if a source changes
select lvl, source_node, target_node, job_num, action_type, edge_origin
from   table(lin_engine.trace_object('SCD_CON_DTL', 'DOWNSTREAM'));

--------------------------------------------------------------------------------
-- 7. Column lineage: how is a column calculated?
--------------------------------------------------------------------------------
-- one hop: the expression that produces each column of an object
select target_column, column_pos, transform_type, expression, source_object, source_column,
       ref_role, resolution, lineage_origin, job_num
from   lin_v_column_lineage
where  target_object = 'APP_SNAP_BKG_V'
order  by column_pos, source_object, source_column;

-- full upstream chain to the base tables
select lvl, target_object, target_column, transform_type, expression,
       source_object, source_column, ref_role, job_num, path
from   table(lin_engine.trace_column('SNAP_BKG', 'TCV_USD', 'UPSTREAM'));

-- where does a source column flow to?
select lvl, source_object, source_column, target_object, target_column, transform_type, path
from   table(lin_engine.trace_column('SRC_FX_RATE', 'RATE', 'DOWNSTREAM'));

-- calculated columns (anything that is not a straight copy)
select target_object, target_column, transform_type, expression
from   lin_v_column_lineage
where  transform_type in ('CALCULATED', 'CASE', 'AGGREGATE', 'WINDOW')
group  by target_object, target_column, transform_type, expression
order  by target_object, target_column;

-- references the parser could not tie to an object (review these)
select target_object, target_column, expression, source_column, resolution
from   lin_v_column_lineage
where  resolution in ('AMBIGUOUS', 'UNRESOLVED')
order  by target_object, target_column;

--------------------------------------------------------------------------------
-- 8. Syntax tree of a parsed statement (tree-sitter style)
--------------------------------------------------------------------------------
select lpad(' ', 2 * depth) || node_type
       || nvl2(node_name, ' [' || substr(node_name, 1, 40) || ']', '') tree,
       start_pos, end_pos, substr(node_text, 1, 80) node_text
from  (select * from lin_ast_node
       where parse_id = (select max(parse_id) from lin_parse
                         where run_id = (select run_id from lin_v_latest_run)
                         and   object_name = 'APP_SNAP_BKG_V'))
start  with parent_id is null
connect by prior node_id = parent_id
order  siblings by sibling_seq;

-- ad-hoc: parse any statement without storing it
select lpad(' ', 2 * depth) || node_type || nvl2(node_name, ' [' || node_name || ']', '') tree, node_text
from   table(lin_sql_parser.parse_tree(
         'select a.x, sum(b.y * 2) total from t1 a join t2 b on b.id = a.id group by a.x'));

-- every column reference inside the WHERE clauses of a view
select n.node_name column_ref, w.node_text where_clause
from   lin_ast_node w
join   lin_ast_node n on n.parse_id = w.parse_id
                     and n.node_type = 'COLUMN_REF'
                     and n.start_pos between w.start_pos and w.end_pos
where  w.node_type = 'WHERE'
and    w.parse_id = (select max(parse_id) from lin_parse where object_name = 'STG_SCD_CON_S5_V');

--------------------------------------------------------------------------------
-- 9. Compare two runs (what changed in the pipeline)
--------------------------------------------------------------------------------
select 'ADDED' change, source_node, target_node, job_num from (
  select source_node, target_node, job_num from lin_edge where run_id = (select max(run_id) from lin_run where status = 'COMPLETED')
  minus
  select source_node, target_node, job_num from lin_edge where run_id = (select max(run_id) from lin_run where status = 'COMPLETED'
                                                                         and run_id < (select max(run_id) from lin_run where status = 'COMPLETED')))
union all
select 'REMOVED', source_node, target_node, job_num from (
  select source_node, target_node, job_num from lin_edge where run_id = (select max(run_id) from lin_run where status = 'COMPLETED'
                                                                         and run_id < (select max(run_id) from lin_run where status = 'COMPLETED'))
  minus
  select source_node, target_node, job_num from lin_edge where run_id = (select max(run_id) from lin_run where status = 'COMPLETED'));
