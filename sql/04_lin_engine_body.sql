--------------------------------------------------------------------------------
-- 04_lin_engine_body.sql
--------------------------------------------------------------------------------
set define off
create or replace package body lin_engine as

  type t_flags is table of boolean      index by varchar2(1000);
  type t_ints  is table of pls_integer  index by pls_integer;
  type t_adj   is table of t_ints       index by pls_integer;
  type t_idx   is table of pls_integer  index by varchar2(261);
  type t_strs  is table of varchar2(261) index by pls_integer;

  g_run_id    number;
  g_owner     varchar2(128);
  g_save_ast  boolean;
  g_edge_seen t_flags;
  g_jobj_seen t_flags;

  ------------------------------------------------------------------------------
  -- Helpers
  ------------------------------------------------------------------------------
  function is_disabled (p_flag in varchar2) return varchar2 deterministic is
  begin
    return case
             when upper(trim(p_flag)) in ('Y', 'YES', 'TRUE', '1', 'X', 'D', 'DEL', 'DELETED',
                                          'DISABLED', 'INACTIVE', 'OFF')
             then 'Y' else 'N'
           end;
  end is_disabled;

  -- canonical node name: upper case, no quotes, owner prefix removed for the run owner
  function norm (p_name varchar2) return varchar2 is
    l varchar2(4000) := upper(trim(replace(p_name, '"')));
  begin
    l := regexp_replace(l, '\s+', ' ');
    if l like g_owner || '.%' then
      l := substr(l, length(g_owner) + 2);
    end if;
    return substr(l, 1, 261);
  end norm;

  function is_label (p_name varchar2) return boolean is
  begin
    return p_name is null or regexp_like(p_name, '^\s*SQL\s*:', 'i');
  end is_label;

  function is_dual (p_name varchar2) return boolean is
  begin
    return p_name in ('DUAL', 'SYS.DUAL', 'PUBLIC.DUAL');
  end is_dual;

  function owner_of (p_name varchar2) return varchar2 is
  begin
    return case when instr(p_name, '.') > 0 then substr(p_name, 1, instr(p_name, '.') - 1) else g_owner end;
  end owner_of;

  function name_of (p_name varchar2) return varchar2 is
  begin
    return case when instr(p_name, '.') > 0 then substr(p_name, instr(p_name, '.') + 1) else p_name end;
  end name_of;

  function clean_sql (p_sql clob) return clob is
    l clob;
  begin
    if p_sql is null or dbms_lob.getlength(p_sql) = 0 then return null; end if;
    l := replace(replace(p_sql, '_x000D_'), chr(13));
    l := regexp_replace(l, '^\s+|\s+$', '');
    if l is null or dbms_lob.getlength(l) = 0 then return null; end if;
    -- a trailing ';' is not part of a SQL statement (but is part of BEGIN ... END;)
    if not regexp_like(dbms_lob.substr(l, 10, 1), '^\s*(BEGIN|DECLARE)', 'i') then
      l := regexp_replace(l, ';\s*$', '');
    end if;
    return l;
  end clean_sql;

  procedure add_job_object (p_job number, p_obj varchar2, p_role varchar2,
                            p_ctx varchar2, p_from varchar2) is
    k varchar2(1000) := p_job || '|' || p_obj || '|' || p_role || '|' || p_ctx;
  begin
    if p_obj is null or is_dual(p_obj) or g_jobj_seen.exists(k) then return; end if;
    g_jobj_seen(k) := true;
    insert into lin_job_object (run_id, job_num, object_name, object_role, ref_context, derived_from)
    values (g_run_id, p_job, p_obj, p_role, p_ctx, p_from);
  end add_job_object;

  procedure add_edge (p_src varchar2, p_tgt varchar2, p_job number, p_job_names varchar2,
                      p_action varchar2, p_origin varchar2, p_ctx varchar2) is
    k varchar2(1000) := p_src || '|' || p_tgt || '|' || p_job || '|' || p_origin || '|' || p_ctx;
  begin
    if p_src is null or p_tgt is null or is_dual(p_src) or g_edge_seen.exists(k) then return; end if;
    g_edge_seen(k) := true;
    insert into lin_edge (run_id, edge_id, source_node, target_node, job_num, job_names,
                          action_type, edge_origin, ref_context, is_self_loop)
    values (g_run_id, lin_edge_seq.nextval, p_src, p_tgt, p_job, p_job_names,
            p_action, p_origin, p_ctx, case when p_src = p_tgt then 'Y' else 'N' end);
  end add_edge;

  ------------------------------------------------------------------------------
  -- Step 1 & 2 : snapshot jobs and groups
  ------------------------------------------------------------------------------
  procedure load_jobs (p_source_table varchar2) is
    l_src varchar2(400) := dbms_assert.sql_object_name(p_source_table);
  begin
    execute immediate
      'insert into lin_job (run_id, job_num, job_names, target_object, source_object, unique_col,
                            filter_clause, sql_stmt, disabled_flag, is_active, exec_seq)
       select :r, job_num, trim(job_names), trim(target_object), trim(source_object), trim(unique_col),
              filter_clause, sql_stmt, disabled_flag,
              case lin_engine.is_disabled(disabled_flag) when ''Y'' then ''N'' else ''Y'' end,
              row_number() over (order by job_num)
       from ' || l_src
      using g_run_id;

    insert into lin_job_group (run_id, job_num, group_name, group_pos, group_path)
    select j.run_id, j.job_num,
           trim(regexp_substr(j.norm_names, '[^|]+', 1, l.lvl)),
           l.lvl,
           case when instr(j.norm_names, '|', 1, l.lvl) > 0
                then substr(j.norm_names, 1, instr(j.norm_names, '|', 1, l.lvl) - 1)
                else j.norm_names end
    from   (select run_id, job_num,
                   regexp_replace(trim(both '|' from job_names), '\s*\|\s*', '|') norm_names
            from   lin_job
            where  run_id = g_run_id and job_names is not null) j
    cross apply (select level lvl from dual
                 connect by level <= regexp_count(j.norm_names, '\|') + 1) l
    where  trim(regexp_substr(j.norm_names, '[^|]+', 1, l.lvl)) is not null;
  end load_jobs;

  ------------------------------------------------------------------------------
  -- Step 3 : job edges
  ------------------------------------------------------------------------------
  procedure metadata_edges (p_job number, p_names varchar2, p_tgt varchar2, p_src varchar2,
                            p_action varchar2, p_origin varchar2, p_from varchar2) is
  begin
    if p_tgt is not null then add_job_object(p_job, p_tgt, 'TARGET', 'DATA', p_from); end if;
    if p_src is not null then
      add_job_object(p_job, p_src, 'SOURCE', 'DATA', p_from);
      add_edge(p_src, p_tgt, p_job, p_names, p_action, p_origin, 'DATA');
    end if;
  end metadata_edges;

  procedure process_jobs is
    l_sql     clob;
    l_st      varchar2(20);
    l_stype   varchar2(20);
    l_pid     number;
    l_refs    lin_sql_parser.t_obj_refs;
    l_tgts    t_strs;
    l_action  varchar2(30);
    l_msg     varchar2(4000);
    l_tgt     varchar2(261);
    l_src     varchar2(261);
    l_has_src boolean;
    l_obj     varchar2(261);
  begin
    for j in (select * from lin_job where run_id = g_run_id and is_active = 'Y' order by exec_seq) loop
      l_tgt := norm(j.target_object);
      l_src := case when is_label(j.source_object) then null else norm(j.source_object) end;
      l_sql := clean_sql(j.sql_stmt);
      l_msg := null;

      if l_sql is null then
        ----------------------------------------------------------------------
        -- Case A: standard load SOURCE_OBJECT -> TARGET_OBJECT
        ----------------------------------------------------------------------
        l_action := case
                      when upper(j.unique_col) = 'APPEND' then 'LOAD_APPEND'
                      when j.unique_col is not null      then 'LOAD_KEYED'
                      else 'LOAD_REPLACE'
                    end;
        metadata_edges(j.job_num, j.job_names, l_tgt, l_src, l_action, 'JOB_STANDARD', 'METADATA');

        -- objects referenced by an optional FILTER_CLAUSE become FILTER inputs
        if j.filter_clause is not null and l_src is not null then
          l_st := lin_sql_parser.parse('select * from ' || l_src || ' where ' || j.filter_clause,
                                       null, g_owner, false);
          l_refs := lin_sql_parser.obj_refs;
          for i in 1 .. l_refs.count loop
            l_obj := norm(l_refs(i).object_name);
            if l_refs(i).object_role = 'SOURCE' and l_obj != l_src then
              add_job_object(j.job_num, l_obj, 'SOURCE', 'FILTER', 'METADATA');
              add_edge(l_obj, l_tgt, j.job_num, j.job_names, l_action, 'JOB_STANDARD', 'FILTER');
            end if;
          end loop;
        end if;

        update lin_job
        set    case_type = 'A_STANDARD', action_type = l_action, parse_status = 'N_A',
               load_key = case when upper(unique_col) != 'APPEND' then unique_col end
        where  run_id = g_run_id and job_num = j.job_num;

      else
        ----------------------------------------------------------------------
        -- Case B: custom SQL
        ----------------------------------------------------------------------
        l_st    := lin_sql_parser.parse(l_sql, null, g_owner, true);
        l_stype := lin_sql_parser.stmt_type;
        l_refs  := lin_sql_parser.obj_refs;
        l_pid   := lin_sql_parser.save(g_run_id, 'JOB_SQL', j.job_num, l_tgt, 'JOB_SQL', g_save_ast);
        l_msg   := lin_sql_parser.message;

        l_tgts.delete;
        l_has_src := false;
        for i in 1 .. l_refs.count loop
          if l_refs(i).object_role = 'TARGET' then
            l_tgts(l_tgts.count + 1) := norm(l_refs(i).object_name);
          elsif l_refs(i).object_role = 'SOURCE' and not is_dual(norm(l_refs(i).object_name)) then
            l_has_src := true;
          end if;
        end loop;

        l_action := case l_stype
                      when 'INSERT'       then case when l_has_src then 'INSERT_SELECT' else 'INSERT_VALUES' end
                      when 'UPDATE'       then 'UPDATE'
                      when 'DELETE'       then 'DELETE'
                      when 'MERGE'        then 'MERGE'
                      when 'TRUNCATE'     then 'TRUNCATE'
                      when 'PLSQL'        then 'PLSQL_CALL'
                      when 'CREATE_TABLE' then 'CREATE_TABLE_AS'
                      when 'SELECT'       then 'SELECT'
                      else 'UNKNOWN'
                    end;

        if l_st = 'FAILED' or (l_tgts.count = 0 and l_stype != 'PLSQL') then
          -- parsing failed: fall back to the metadata columns
          l_st := 'FALLBACK';
          metadata_edges(j.job_num, j.job_names, l_tgt, l_src, l_action, 'JOB_FALLBACK', 'FALLBACK');

        elsif l_stype = 'PLSQL' then
          -- procedure call: CALL node -> metadata target, metadata source -> target
          if l_tgt is not null then add_job_object(j.job_num, l_tgt, 'TARGET', 'DATA', 'METADATA'); end if;
          for i in 1 .. l_refs.count loop
            l_obj := norm(l_refs(i).object_name);
            if l_refs(i).object_role = 'CALL' then
              add_job_object(j.job_num, l_obj, 'CALL', 'DATA', 'SQL_PARSE');
              add_edge(l_obj, l_tgt, j.job_num, j.job_names, l_action, 'JOB_PLSQL', 'DATA');
            elsif l_refs(i).object_role = 'TARGET' then
              add_job_object(j.job_num, l_obj, 'TARGET', 'DATA', 'SQL_PARSE');
            elsif not is_dual(l_obj) then
              add_job_object(j.job_num, l_obj, 'SOURCE', l_refs(i).ref_context, 'SQL_PARSE');
              add_edge(l_obj, nvl(l_tgt, l_obj), j.job_num, j.job_names, l_action, 'JOB_SQL', l_refs(i).ref_context);
            end if;
          end loop;
          if l_src is not null then
            add_job_object(j.job_num, l_src, 'SOURCE', 'DATA', 'METADATA');
            add_edge(l_src, l_tgt, j.job_num, j.job_names, l_action, 'JOB_PLSQL', 'DATA');
          end if;

        else
          for t in 1 .. l_tgts.count loop
            add_job_object(j.job_num, l_tgts(t), 'TARGET', 'DATA', 'SQL_PARSE');
          end loop;
          for i in 1 .. l_refs.count loop
            l_obj := norm(l_refs(i).object_name);
            if l_refs(i).object_role = 'SOURCE' and not is_dual(l_obj) then
              add_job_object(j.job_num, l_obj, 'SOURCE', l_refs(i).ref_context, 'SQL_PARSE');
              for t in 1 .. l_tgts.count loop
                add_edge(l_obj, l_tgts(t), j.job_num, j.job_names, l_action, 'JOB_SQL', l_refs(i).ref_context);
              end loop;
            end if;
          end loop;
          if l_tgt is not null and l_tgts.count > 0 and l_tgts(1) != l_tgt then
            l_msg := substrb('TARGET_OBJECT ' || l_tgt || ' differs from SQL target ' || l_tgts(1)
                             || case when l_msg is not null then ' | ' || l_msg end, 1, 4000);
          end if;
        end if;

        update lin_job
        set    case_type = 'B_SQL', action_type = l_action, parse_id = l_pid,
               parse_status = l_st, parse_message = l_msg
        where  run_id = g_run_id and job_num = j.job_num;
      end if;
    end loop;
  end process_jobs;

  ------------------------------------------------------------------------------
  -- Step 4 : view definitions
  ------------------------------------------------------------------------------
  function capture_views (p_level pls_integer) return pls_integer is
    l_cnt pls_integer;
  begin
    insert into lin_view_ddl (run_id, owner, view_name, view_text, text_length, capture_level)
    select g_run_id, v.owner, v.view_name, to_lob(v.text), v.text_length, p_level
    from   all_views v
    where  (v.owner, v.view_name) in (
             select case when instr(n, '.') > 0 then substr(n, 1, instr(n, '.') - 1) else g_owner end,
                    case when instr(n, '.') > 0 then substr(n, instr(n, '.') + 1) else n end
             from  (select source_node n from lin_edge where run_id = g_run_id
                    union
                    select target_node from lin_edge where run_id = g_run_id
                    union
                    select object_name from lin_job_object
                    where  run_id = g_run_id and object_role in ('SOURCE', 'TARGET')))
    and    not exists (select 1 from lin_view_ddl x
                       where  x.run_id = g_run_id and x.owner = v.owner and x.view_name = v.view_name);
    l_cnt := sql%rowcount;
    return l_cnt;
  end capture_views;

  procedure process_views (p_level pls_integer, p_use_dependencies boolean) is
    l_st   varchar2(20);
    l_pid  number;
    l_refs lin_sql_parser.t_obj_refs;
    l_view varchar2(261);
    l_obj  varchar2(261);
  begin
    for v in (select owner, view_name, view_text from lin_view_ddl
              where run_id = g_run_id and capture_level = p_level) loop
      l_view := norm(case when v.owner = g_owner then v.view_name else v.owner || '.' || v.view_name end);
      l_st   := lin_sql_parser.parse(v.view_text, l_view, v.owner, true);
      l_refs := lin_sql_parser.obj_refs;
      l_pid  := lin_sql_parser.save(g_run_id, 'VIEW', null, l_view, 'VIEW_DEF', g_save_ast);

      update lin_view_ddl set parse_id = l_pid
      where  run_id = g_run_id and owner = v.owner and view_name = v.view_name;

      for i in 1 .. l_refs.count loop
        if l_refs(i).object_role = 'SOURCE' then
          l_obj := norm(case when v.owner != g_owner and instr(l_refs(i).object_name, '.') = 0
                             then v.owner || '.' || l_refs(i).object_name
                             else l_refs(i).object_name end);
          add_edge(l_obj, l_view, null, null, 'VIEW', 'VIEW_DEF', l_refs(i).ref_context);
        end if;
      end loop;

      if p_use_dependencies then
        -- anything the dictionary knows that the parser did not report
        for d in (select referenced_owner, referenced_name
                  from   all_dependencies
                  where  owner = v.owner and name = v.view_name and type = 'VIEW'
                  and    referenced_type in ('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'SYNONYM')
                  and    referenced_owner not in ('SYS', 'PUBLIC')
                  and    referenced_link_name is null) loop
          l_obj := norm(case when d.referenced_owner = g_owner then d.referenced_name
                             else d.referenced_owner || '.' || d.referenced_name end);
          if l_obj != l_view then
            if not g_edge_seen.exists(l_obj || '|' || l_view || '||VIEW_DEF|DATA')
               and not g_edge_seen.exists(l_obj || '|' || l_view || '||VIEW_DEF|FILTER') then
              add_edge(l_obj, l_view, null, null, 'VIEW', 'DB_DEPENDENCY', 'DATA');
            end if;
          end if;
        end loop;
      end if;
    end loop;
  end process_views;

  ------------------------------------------------------------------------------
  -- Column lineage of standard loads (name matching through the dictionary)
  ------------------------------------------------------------------------------
  procedure standard_column_lineage is
  begin
    insert into lin_column_lineage (run_id, parse_id, lineage_origin, job_num, target_object,
                                    target_column, column_pos, expression, transform_type,
                                    source_object, source_column, ref_role, resolution)
    select g_run_id, null, 'JOB_STANDARD', j.job_num, j.tgt, tc.column_name, tc.column_id,
           j.src || '.' || sc.column_name, 'DIRECT', j.src, sc.column_name,
           case when upper(j.unique_col) = tc.column_name then 'KEY' else 'VALUE' end,
           'DICTIONARY'
    from  (select jb.job_num, jb.unique_col, t.object_name tgt, s.object_name src
           from   lin_job jb
           join   lin_job_object t on t.run_id = jb.run_id and t.job_num = jb.job_num
                                  and t.object_role = 'TARGET' and t.derived_from = 'METADATA'
           join   lin_job_object s on s.run_id = jb.run_id and s.job_num = jb.job_num
                                  and s.object_role = 'SOURCE' and s.ref_context = 'DATA'
                                  and s.derived_from = 'METADATA'
           where  jb.run_id = g_run_id and jb.case_type = 'A_STANDARD') j
    join   all_tab_columns tc
           on  tc.owner = case when instr(j.tgt, '.') > 0 then substr(j.tgt, 1, instr(j.tgt, '.') - 1) else g_owner end
           and tc.table_name = case when instr(j.tgt, '.') > 0 then substr(j.tgt, instr(j.tgt, '.') + 1) else j.tgt end
    join   all_tab_columns sc
           on  sc.owner = case when instr(j.src, '.') > 0 then substr(j.src, 1, instr(j.src, '.') - 1) else g_owner end
           and sc.table_name = case when instr(j.src, '.') > 0 then substr(j.src, instr(j.src, '.') + 1) else j.src end
           and sc.column_name = tc.column_name;

    -- no dictionary information: record a pass-through of all columns
    insert into lin_column_lineage (run_id, parse_id, lineage_origin, job_num, target_object,
                                    target_column, column_pos, expression, transform_type,
                                    source_object, source_column, ref_role, resolution)
    select g_run_id, null, 'JOB_STANDARD', jb.job_num, t.object_name, '*', null,
           s.object_name || '.*', 'STAR', s.object_name, '*', 'VALUE', 'UNEXPANDED'
    from   lin_job jb
    join   lin_job_object t on t.run_id = jb.run_id and t.job_num = jb.job_num
                           and t.object_role = 'TARGET' and t.derived_from = 'METADATA'
    join   lin_job_object s on s.run_id = jb.run_id and s.job_num = jb.job_num
                           and s.object_role = 'SOURCE' and s.ref_context = 'DATA'
                           and s.derived_from = 'METADATA'
    where  jb.run_id = g_run_id and jb.case_type = 'A_STANDARD'
    and    not exists (select 1 from lin_column_lineage c
                       where  c.run_id = g_run_id and c.job_num = jb.job_num
                       and    c.lineage_origin = 'JOB_STANDARD');
  end standard_column_lineage;

  ------------------------------------------------------------------------------
  -- Step 5 : nodes, classification, DAG levels
  ------------------------------------------------------------------------------
  procedure build_nodes is
    l_type varchar2(30);
    l_src  varchar2(20);
    l_own  varchar2(128);
    l_nm   varchar2(261);
  begin
    insert into lin_node (run_id, node_name)
    select g_run_id, n from (
      select source_node n from lin_edge where run_id = g_run_id
      union
      select target_node from lin_edge where run_id = g_run_id
      union
      select object_name from lin_job_object where run_id = g_run_id);

    for n in (select node_name from lin_node where run_id = g_run_id) loop
      l_type := null;
      l_src  := 'HEURISTIC';
      for c in (select 1 from lin_job_object
                where run_id = g_run_id and object_name = n.node_name and object_role = 'CALL'
                and rownum = 1) loop
        l_type := 'PROCEDURE';
      end loop;
      if l_type is null and not regexp_like(n.node_name, '^[A-Z][A-Z0-9_$#]*(\.[A-Z][A-Z0-9_$#]*)?(@[A-Z0-9_$#.]+)?$') then
        l_type := 'PSEUDO';
      end if;
      if l_type is null then
        l_own := owner_of(n.node_name);
        l_nm  := name_of(n.node_name);
        for o in (select object_type from all_objects
                  where  owner = l_own and object_name = l_nm
                  and    object_type in ('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'SYNONYM')
                  order  by case object_type when 'MATERIALIZED VIEW' then 1 when 'TABLE' then 2
                                             when 'VIEW' then 3 else 4 end) loop
          l_type := o.object_type;
          l_src  := 'DICTIONARY';
          exit;
        end loop;
      end if;
      if l_type is null then
        l_type := case when regexp_like(n.node_name, '_V$') then 'VIEW' else 'TABLE' end;
      end if;
      update lin_node set node_type = l_type, type_source = l_src
      where  run_id = g_run_id and node_name = n.node_name;
    end loop;

    update lin_node n
    set in_degree      = (select count(distinct e.source_node) from lin_edge e
                          where e.run_id = n.run_id and e.target_node = n.node_name and e.is_self_loop = 'N'),
        out_degree     = (select count(distinct e.target_node) from lin_edge e
                          where e.run_id = n.run_id and e.source_node = n.node_name and e.is_self_loop = 'N'),
        job_in_degree  = (select count(distinct e.source_node) from lin_edge e
                          where e.run_id = n.run_id and e.target_node = n.node_name and e.is_self_loop = 'N'
                          and e.job_num is not null),
        job_out_degree = (select count(distinct e.target_node) from lin_edge e
                          where e.run_id = n.run_id and e.source_node = n.node_name and e.is_self_loop = 'N'
                          and e.job_num is not null),
        writer_jobs    = (select count(distinct o.job_num) from lin_job_object o
                          where o.run_id = n.run_id and o.object_name = n.node_name and o.object_role = 'TARGET'),
        reader_jobs    = (select count(distinct o.job_num) from lin_job_object o
                          where o.run_id = n.run_id and o.object_name = n.node_name and o.object_role = 'SOURCE'),
        first_writer_job = (select min(o.job_num) from lin_job_object o
                          where o.run_id = n.run_id and o.object_name = n.node_name and o.object_role = 'TARGET'),
        last_writer_job  = (select max(o.job_num) from lin_job_object o
                          where o.run_id = n.run_id and o.object_name = n.node_name and o.object_role = 'TARGET'),
        view_captured  = case when exists (select 1 from lin_view_ddl v
                                           where v.run_id = n.run_id
                                           and   v.owner = case when instr(n.node_name, '.') > 0
                                                                then substr(n.node_name, 1, instr(n.node_name, '.') - 1)
                                                                else g_owner end
                                           and   v.view_name = case when instr(n.node_name, '.') > 0
                                                                then substr(n.node_name, instr(n.node_name, '.') + 1)
                                                                else n.node_name end)
                              then 'Y' else 'N' end
    where n.run_id = g_run_id;

    update lin_node
    set node_class = case
                       when in_degree = 0 and out_degree = 0 then 'ISOLATED'
                       when in_degree = 0 then 'ROOT'
                       when out_degree = 0 then 'TERMINAL'
                       else 'INTERMEDIATE'
                     end,
        job_node_class = case
                       when writer_jobs + reader_jobs = 0 and job_in_degree + job_out_degree = 0 then 'VIEW_ONLY'
                       when job_in_degree = 0 and job_out_degree = 0 then 'ISOLATED'
                       when job_in_degree = 0 then 'ROOT'
                       when job_out_degree = 0 then 'TERMINAL'
                       else 'INTERMEDIATE'
                     end
    where run_id = g_run_id;
  end build_nodes;

  -- Tarjan SCC + longest path on the condensation => DAG level, cycle flag
  procedure compute_levels is
    l_idx     t_idx;
    l_name    t_strs;
    l_adj     t_adj;
    l_index   t_ints;
    l_low     t_ints;
    l_onstk   t_ints;
    l_stack   t_ints;
    l_comp    t_ints;
    l_csize   t_ints;
    l_cadj    t_adj;
    l_cindeg  t_ints;
    l_clevel  t_ints;
    l_queue   t_ints;
    l_counter pls_integer := 0;
    l_ncomp   pls_integer := 0;
    n         pls_integer := 0;
    u         pls_integer;
    v         pls_integer;
    c         pls_integer;
    head      pls_integer;

    procedure strongconnect (p_v pls_integer) is
      w pls_integer;
    begin
      l_counter := l_counter + 1;
      l_index(p_v) := l_counter;
      l_low(p_v)   := l_counter;
      l_stack(l_stack.count + 1) := p_v;
      l_onstk(p_v) := 1;
      if l_adj.exists(p_v) then
        for k in 1 .. l_adj(p_v).count loop
          w := l_adj(p_v)(k);
          if not l_index.exists(w) then
            strongconnect(w);
            l_low(p_v) := least(l_low(p_v), l_low(w));
          elsif l_onstk(w) = 1 then
            l_low(p_v) := least(l_low(p_v), l_index(w));
          end if;
        end loop;
      end if;
      if l_low(p_v) = l_index(p_v) then
        l_ncomp := l_ncomp + 1;
        l_csize(l_ncomp) := 0;
        loop
          w := l_stack(l_stack.count);
          l_stack.delete(l_stack.count);
          l_onstk(w) := 0;
          l_comp(w) := l_ncomp;
          l_csize(l_ncomp) := l_csize(l_ncomp) + 1;
          exit when w = p_v;
        end loop;
      end if;
    end strongconnect;
  begin
    for r in (select node_name from lin_node where run_id = g_run_id order by node_name) loop
      n := n + 1;
      l_idx(r.node_name) := n;
      l_name(n) := r.node_name;
      l_onstk(n) := 0;
    end loop;
    for e in (select distinct source_node, target_node from lin_edge
              where run_id = g_run_id and is_self_loop = 'N') loop
      u := l_idx(e.source_node);
      v := l_idx(e.target_node);
      if not l_adj.exists(u) then l_adj(u)(1) := v; else l_adj(u)(l_adj(u).count + 1) := v; end if;
    end loop;

    for i in 1 .. n loop
      if not l_index.exists(i) then strongconnect(i); end if;
    end loop;

    -- condensation graph
    for i in 1 .. l_ncomp loop l_cindeg(i) := 0; l_clevel(i) := 0; end loop;
    for i in 1 .. n loop
      if l_adj.exists(i) then
        for k in 1 .. l_adj(i).count loop
          u := l_comp(i);
          v := l_comp(l_adj(i)(k));
          if u != v then
            if not l_cadj.exists(u) then l_cadj(u)(1) := v; else l_cadj(u)(l_cadj(u).count + 1) := v; end if;
            l_cindeg(v) := l_cindeg(v) + 1;
          end if;
        end loop;
      end if;
    end loop;
    for i in 1 .. l_ncomp loop
      if l_cindeg(i) = 0 then l_queue(l_queue.count + 1) := i; end if;
    end loop;
    head := 1;
    while head <= l_queue.count loop
      c := l_queue(head);
      head := head + 1;
      if l_cadj.exists(c) then
        for k in 1 .. l_cadj(c).count loop
          v := l_cadj(c)(k);
          l_clevel(v) := greatest(l_clevel(v), l_clevel(c) + 1);
          l_cindeg(v) := l_cindeg(v) - 1;
          if l_cindeg(v) = 0 then l_queue(l_queue.count + 1) := v; end if;
        end loop;
      end if;
    end loop;

    for i in 1 .. n loop
      update lin_node
      set    dag_level = l_clevel(l_comp(i)),
             in_cycle  = case when l_csize(l_comp(i)) > 1 then 'Y' else 'N' end
      where  run_id = g_run_id and node_name = l_name(i);
    end loop;
  end compute_levels;

  ------------------------------------------------------------------------------
  -- Job -> job dependencies (through any number of view layers)
  ------------------------------------------------------------------------------
  procedure job_dependencies is
  begin
    insert into lin_job_dep (run_id, job_num, depends_on_job, via_object, read_object, hops,
                             dep_type, is_latest_writer, same_group)
    with writers as (
      select distinct o.job_num, o.object_name, j.exec_seq
      from   lin_job_object o
      join   lin_job j on j.run_id = o.run_id and j.job_num = o.job_num
      where  o.run_id = g_run_id and o.object_role = 'TARGET'
    ), reads as (
      select distinct o.job_num, o.object_name, j.exec_seq
      from   lin_job_object o
      join   lin_job j on j.run_id = o.run_id and j.job_num = o.job_num
      where  o.run_id = g_run_id and o.object_role = 'SOURCE'
    ), vedges as (
      select distinct source_node, target_node
      from   lin_edge
      where  run_id = g_run_id and job_num is null and is_self_loop = 'N'
    ), walk (job_num, exec_seq, read_object, cur_object, hops) as (
      select job_num, exec_seq, object_name, object_name, 0 from reads
      union all
      select w.job_num, w.exec_seq, w.read_object, e.source_node, w.hops + 1
      from   walk w
      join   vedges e on e.target_node = w.cur_object
      where  w.hops < 30
      and    not exists (select 1 from writers x where x.object_name = w.cur_object)
    ) cycle cur_object set is_cycle to 'Y' default 'N'
    , deps as (
      select w.job_num, p.job_num depends_on_job, w.cur_object via_object, w.read_object,
             min(w.hops) hops, max(w.exec_seq) c_seq, max(p.exec_seq) p_seq
      from   walk w
      join   writers p on p.object_name = w.cur_object and p.job_num != w.job_num
      group  by w.job_num, p.job_num, w.cur_object, w.read_object
    )
    select g_run_id, d.job_num, d.depends_on_job, d.via_object, d.read_object, d.hops,
           case when d.p_seq < d.c_seq then 'PRIOR_STEP' else 'PRIOR_CYCLE' end,
           case when d.p_seq = max(case when d.p_seq < d.c_seq then d.p_seq end)
                                 over (partition by d.job_num, d.via_object)
                then 'Y' else 'N' end,
           case when exists (select 1
                             from   lin_job_group g1
                             join   lin_job_group g2 on g2.run_id = g1.run_id and g2.group_name = g1.group_name
                             where  g1.run_id = g_run_id and g1.job_num = d.job_num
                             and    g2.job_num = d.depends_on_job)
                then 'Y' else 'N' end
    from   deps d;
  end job_dependencies;

  ------------------------------------------------------------------------------
  -- Run
  ------------------------------------------------------------------------------
  procedure fail_run (p_run_id number, p_msg varchar2) is
    pragma autonomous_transaction;
  begin
    update lin_run set status = 'FAILED', finished_at = systimestamp, message = substrb(p_msg, 1, 4000)
    where  run_id = p_run_id;
    commit;
  end fail_run;

  function run (
    p_source_table     in varchar2 default 'BOOK_JOBS',
    p_owner            in varchar2 default null,
    p_run_label        in varchar2 default null,
    p_capture_views    in boolean  default true,
    p_view_depth       in pls_integer default 25,
    p_use_dependencies in boolean  default true,
    p_save_ast         in boolean  default true
  ) return number is
    l_lvl pls_integer := 0;
    l_new pls_integer;
  begin
    g_owner    := upper(nvl(p_owner, sys_context('USERENV', 'CURRENT_SCHEMA')));
    g_save_ast := nvl(p_save_ast, true);
    g_edge_seen.delete;
    g_jobj_seen.delete;
    lin_sql_parser.clear_cache;
    g_run_id := lin_run_seq.nextval;

    insert into lin_run (run_id, run_label, source_table, object_owner)
    values (g_run_id, p_run_label, upper(p_source_table), g_owner);
    commit;

    begin
      load_jobs(p_source_table);
      process_jobs;

      if nvl(p_capture_views, true) then
        loop
          l_new := capture_views(l_lvl);
          exit when l_new = 0;
          process_views(l_lvl, nvl(p_use_dependencies, true));
          l_lvl := l_lvl + 1;
          exit when l_lvl > p_view_depth;
        end loop;
      end if;

      standard_column_lineage;
      build_nodes;
      compute_levels;
      job_dependencies;

      update lin_run r
      set    status         = 'COMPLETED',
             finished_at    = systimestamp,
             rows_read      = (select count(*) from lin_job where run_id = r.run_id),
             rows_active    = (select count(*) from lin_job where run_id = r.run_id and is_active = 'Y'),
             rows_disabled  = (select count(*) from lin_job where run_id = r.run_id and is_active = 'N'),
             sql_parsed     = (select count(*) from lin_job where run_id = r.run_id and parse_status in ('OK', 'PARTIAL')),
             sql_fallback   = (select count(*) from lin_job where run_id = r.run_id and parse_status = 'FALLBACK'),
             views_captured = (select count(*) from lin_view_ddl where run_id = r.run_id),
             edge_count     = (select count(*) from lin_edge where run_id = r.run_id),
             node_count     = (select count(*) from lin_node where run_id = r.run_id)
      where  run_id = g_run_id;
      commit;
    exception
      when others then
        rollback;
        fail_run(g_run_id, sqlerrm || ' ' || dbms_utility.format_error_backtrace);
        raise;
    end;
    return g_run_id;
  end run;

  procedure run (
    p_source_table     in varchar2 default 'BOOK_JOBS',
    p_owner            in varchar2 default null,
    p_run_label        in varchar2 default null,
    p_capture_views    in boolean  default true,
    p_view_depth       in pls_integer default 25,
    p_use_dependencies in boolean  default true,
    p_save_ast         in boolean  default true
  ) is
    l_run number;
  begin
    l_run := run(p_source_table, p_owner, p_run_label, p_capture_views, p_view_depth,
                 p_use_dependencies, p_save_ast);
    print_summary(l_run);
  end run;

  ------------------------------------------------------------------------------
  -- Traces
  ------------------------------------------------------------------------------
  function latest_run return number is
    l number;
  begin
    select max(run_id) into l from lin_run where status = 'COMPLETED';
    return l;
  end latest_run;

  -- Breadth-first walk over LIN_COLUMN_LINEAGE: every (object, column) is
  -- expanded once, so wide fan-in / fan-out graphs stay linear.
  function trace_column (
    p_object    in varchar2,
    p_column    in varchar2,
    p_direction in varchar2 default 'UPSTREAM',
    p_run_id    in number   default null,
    p_max_depth in pls_integer default 30
  ) return t_trace_tab pipelined is
    type t_q  is record (obj varchar2(261), col varchar2(128), lvl pls_integer, path varchar2(4000));
    type t_qs is table of t_q index by pls_integer;
    l_run   number := nvl(p_run_id, latest_run);
    l_up    boolean := upper(nvl(p_direction, 'UP')) not like 'DOWN%';
    q       t_qs;
    head    pls_integer := 1;
    cur     t_q;
    seen    t_flags;
    emitted t_flags;
    r       t_trace_row;
    k       varchar2(1000);
    nobj    varchar2(261);
    ncol    varchar2(128);
  begin
    q(1).obj := upper(trim(p_object));
    q(1).col := upper(trim(p_column));
    q(1).lvl := 0;
    q(1).path := q(1).obj || '.' || q(1).col;
    seen(q(1).obj || '|' || q(1).col) := true;
    while head <= q.count loop
      cur := q(head);
      head := head + 1;
      exit when cur.lvl >= p_max_depth;
      for c in (select target_object, target_column, expression, transform_type, source_object,
                       source_column, ref_role, lineage_origin, job_num
                from   lin_column_lineage
                where  run_id = l_run
                and    ((l_up and target_object = cur.obj and target_column in (cur.col, '*'))
                     or (not l_up and source_object = cur.obj and source_column in (cur.col, '*')))
                order  by job_num nulls first, source_object, source_column, target_object, target_column) loop
        r.lvl            := cur.lvl + 1;
        r.expression     := c.expression;
        r.transform_type := c.transform_type;
        r.ref_role       := c.ref_role;
        r.lineage_origin := c.lineage_origin;
        r.job_num        := c.job_num;
        if l_up then
          r.target_object := c.target_object;
          r.target_column := cur.col;
          r.source_object := c.source_object;
          r.source_column := case when c.source_column = '*' then cur.col else c.source_column end;
          nobj := r.source_object;
          ncol := r.source_column;
          r.path := substrb(cur.path || ' <- ' || nvl2(nobj, nobj || '.' || ncol, '(constant)'), 1, 4000);
        else
          r.source_object := c.source_object;
          r.source_column := cur.col;
          r.target_object := c.target_object;
          r.target_column := case when c.target_column = '*' then cur.col else c.target_column end;
          nobj := r.target_object;
          ncol := r.target_column;
          r.path := substrb(cur.path || ' -> ' || nobj || '.' || ncol, 1, 4000);
        end if;
        k := r.target_object || '|' || r.target_column || '|' || r.source_object || '|' || r.source_column
             || '|' || r.job_num || '|' || r.lineage_origin || '|' || r.ref_role;
        if not emitted.exists(k) then
          emitted(k) := true;
          pipe row (r);
          if nobj is not null and ncol is not null and ncol != '*'
             and not seen.exists(nobj || '|' || ncol) then
            seen(nobj || '|' || ncol) := true;
            q(q.count + 1).obj := nobj;
            q(q.count).col  := ncol;
            q(q.count).lvl  := cur.lvl + 1;
            q(q.count).path := r.path;
          end if;
        end if;
      end loop;
    end loop;
    return;
  end trace_column;

  function trace_object (
    p_object    in varchar2,
    p_direction in varchar2 default 'UPSTREAM',
    p_run_id    in number   default null,
    p_max_depth in pls_integer default 50
  ) return t_obj_trace_tab pipelined is
    type t_q  is record (obj varchar2(261), lvl pls_integer, path varchar2(4000));
    type t_qs is table of t_q index by pls_integer;
    l_run number := nvl(p_run_id, latest_run);
    l_up  boolean := upper(nvl(p_direction, 'UP')) not like 'DOWN%';
    q     t_qs;
    head  pls_integer := 1;
    cur   t_q;
    seen  t_flags;
    r     t_obj_trace_row;
    nxt   varchar2(261);
  begin
    q(1).obj := upper(trim(p_object));
    q(1).lvl := 0;
    q(1).path := q(1).obj;
    seen(q(1).obj) := true;
    while head <= q.count loop
      cur := q(head);
      head := head + 1;
      exit when cur.lvl >= p_max_depth;
      for e in (select source_node, target_node, job_num, job_names, action_type, edge_origin, ref_context
                from   lin_edge
                where  run_id = l_run and is_self_loop = 'N'
                and    ((l_up and target_node = cur.obj) or (not l_up and source_node = cur.obj))
                order  by job_num nulls first, source_node, target_node) loop
        nxt := case when l_up then e.source_node else e.target_node end;
        r.lvl := cur.lvl + 1;
        r.source_node := e.source_node;
        r.target_node := e.target_node;
        r.job_num := e.job_num;
        r.job_names := e.job_names;
        r.action_type := e.action_type;
        r.edge_origin := e.edge_origin;
        r.ref_context := e.ref_context;
        r.path := substrb(cur.path || case when l_up then ' <- ' else ' -> ' end || nxt, 1, 4000);
        pipe row (r);
        if not seen.exists(nxt) then
          seen(nxt) := true;
          q(q.count + 1).obj := nxt;
          q(q.count).lvl := cur.lvl + 1;
          q(q.count).path := r.path;
        end if;
      end loop;
    end loop;
    return;
  end trace_object;

  function view_ddl (p_view in varchar2, p_owner in varchar2 default null) return clob is
  begin
    return dbms_metadata.get_ddl('VIEW', upper(p_view),
                                 upper(nvl(p_owner, sys_context('USERENV', 'CURRENT_SCHEMA'))));
  end view_ddl;

  procedure print_summary (p_run_id in number default null) is
    l_run number := nvl(p_run_id, latest_run);
  begin
    for r in (select * from lin_run where run_id = l_run) loop
      dbms_output.put_line('Run ' || r.run_id || ' [' || r.status || '] owner=' || r.object_owner
                           || ' source=' || r.source_table);
      dbms_output.put_line('  jobs read=' || r.rows_read || ' active=' || r.rows_active
                           || ' disabled=' || r.rows_disabled);
      dbms_output.put_line('  sql parsed=' || r.sql_parsed || ' fallback=' || r.sql_fallback
                           || ' views captured=' || r.views_captured);
      dbms_output.put_line('  nodes=' || r.node_count || ' edges=' || r.edge_count);
    end loop;
    for c in (select node_class, count(*) cnt from lin_node where run_id = l_run
              group by node_class order by node_class) loop
      dbms_output.put_line('  ' || rpad(c.node_class, 14) || c.cnt);
    end loop;
    for c in (select count(*) cnt from lin_node where run_id = l_run and in_cycle = 'Y') loop
      if c.cnt > 0 then
        dbms_output.put_line('  nodes in cycles: ' || c.cnt);
      end if;
    end loop;
  end print_summary;

end lin_engine;
/
