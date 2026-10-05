--------------------------------------------------------------------------------
-- 07_apex_support.sql
-- Views used by the APEX "Lineage Explorer" page (docs/APEX_LINEAGE_EXPLORER.md).
-- Run in the schema that owns the LIN_* tables (= the APEX parsing schema).
--------------------------------------------------------------------------------
set define off

-- Objects that have column lineage (as target or source), for the Object LOV
create or replace view lin_v_apex_object_lov as
select o.object_name                                                    display_value,
       o.object_name                                                    return_value,
       nvl(n.node_type, 'UNKNOWN')                                      node_type,
       nvl(n.node_class, '-')                                           node_class
from  (select target_object object_name from lin_v_column_lineage
       union
       select source_object from lin_v_column_lineage where source_object is not null) o
left  join lin_v_nodes n on n.node_name = o.object_name;

-- Columns per object (target columns plus columns only ever used as a source)
create or replace view lin_v_apex_column_lov as
select object_name, column_name, min(column_pos) column_pos
from  (select target_object object_name, target_column column_name, column_pos
       from   lin_v_column_lineage
       where  target_column != '*'
       union all
       select source_object, source_column, null
       from   lin_v_column_lineage
       where  source_object is not null and source_column is not null and source_column != '*')
group by object_name, column_name;

-- One row per target column: how it is calculated and from what
create or replace view lin_v_apex_column_calc as
select target_object,
       target_column,
       min(column_pos)                                                  column_pos,
       max(expression)                                                  expression,
       max(transform_type) keep (dense_rank last order by
           case transform_type when 'WINDOW' then 6 when 'AGGREGATE' then 5 when 'CASE' then 4
                               when 'CALCULATED' then 3 when 'RENAME' then 2 when 'DIRECT' then 1
                               else 0 end)                              transform_type,
       listagg(case when ref_role = 'VALUE' and source_object is not null
                    then source_object || '.' || source_column end, ', ' on overflow truncate)
         within group (order by source_object, source_column)          value_sources,
       listagg(case when ref_role in ('CONDITION', 'WINDOW', 'KEY') and source_object is not null
                    then source_object || '.' || source_column || ' (' || lower(ref_role) || ')' end, ', ' on overflow truncate)
         within group (order by source_object, source_column)          condition_sources,
       max(lineage_origin)                                              lineage_origin,
       listagg(distinct to_char(job_num), ', ' on overflow truncate) within group (order by to_char(job_num)) job_nums,
       max(case when resolution in ('AMBIGUOUS', 'UNRESOLVED') then 'Y' else 'N' end) has_unresolved
from   lin_v_column_lineage
group  by target_object, target_column;
