--------------------------------------------------------------------------------
-- 03_lin_sql_parser_body.sql
--------------------------------------------------------------------------------
set define off
create or replace package body lin_sql_parser as

  ------------------------------------------------------------------------------
  -- Internal types
  ------------------------------------------------------------------------------
  type t_tok is record (
    ttype varchar2(8),          -- ID QID STR NUM BIND OP ( ) , ; . EOF
    txt   varchar2(32767),
    utxt  varchar2(32767),      -- upper-cased ID / unquoted QID
    spos  pls_integer,
    epos  pls_integer
  );
  type t_toks      is table of t_tok        index by pls_integer;
  type t_set       is table of boolean      index by varchar2(128);
  type t_names     is table of varchar2(128) index by pls_integer;
  type t_names_qb  is table of t_names      index by pls_integer;
  type t_dict      is table of t_names      index by varchar2(261);
  type t_ints      is table of pls_integer  index by pls_integer;
  type t_ast_idx   is table of t_ast_row    index by pls_integer;

  type t_einfo is record (
    node       pls_integer,
    atoms      pls_integer := 0,
    n_refs     pls_integer := 0,
    simple_col varchar2(128),
    has_agg    boolean := false,
    has_win    boolean := false,
    has_case   boolean := false,
    has_subq   boolean := false
  );

  -- query blocks (SELECT, set operation, UPDATE/MERGE/VALUES pseudo blocks)
  type t_qb is record (
    kind      varchar2(10),
    outer_qb  pls_integer,
    out_done  boolean := false,
    visiting  boolean := false,
    out_first pls_integer,
    out_cnt   pls_integer := 0
  );
  type t_qbs is table of t_qb index by pls_integer;

  type t_src is record (qb pls_integer, alias varchar2(261), obj varchar2(261), dq pls_integer, cte pls_integer);
  type t_srcs is table of t_src index by pls_integer;

  type t_item is record (
    qb         pls_integer,
    pos        pls_integer,
    name       varchar2(128),
    expr       varchar2(4000),
    transform  varchar2(20),
    is_star    boolean := false,
    star_qual  varchar2(261),
    agg_no_ref boolean := false
  );
  type t_items is table of t_item index by pls_integer;

  type t_cref is record (qb pls_integer, item_pos pls_integer, clause varchar2(10),
                         qual varchar2(261), col varchar2(128), role varchar2(20));
  type t_crefs is table of t_cref index by pls_integer;

  type t_sq is record (qb pls_integer, item_pos pls_integer, sq pls_integer, sq_pos pls_integer);
  type t_sqs is table of t_sq index by pls_integer;

  type t_cte is record (name varchar2(128), qb pls_integer);
  type t_ctes is table of t_cte index by pls_integer;

  type t_br is record (setop pls_integer, br pls_integer);
  type t_brs is table of t_br index by pls_integer;

  type t_lin is record (obj varchar2(261), col varchar2(128), transform varchar2(20),
                        role varchar2(20), resolution varchar2(30));
  type t_lins is table of t_lin index by pls_integer;

  type t_out is record (name varchar2(128), expr varchar2(4000), transform varchar2(20), lins t_lins);
  type t_outs is table of t_out index by pls_integer;

  ------------------------------------------------------------------------------
  -- State
  ------------------------------------------------------------------------------
  g_sql        clob;
  g_len        pls_integer := 0;
  g_buf        varchar2(32767);
  g_buf_start  pls_integer;
  g_buf_len    pls_integer := 0;

  g_tok        t_toks;
  g_ntok       pls_integer := 0;
  g_p          pls_integer := 1;
  g_eof        t_tok;

  g_ast        t_ast_idx;
  g_kids       t_ints;

  g_status     varchar2(20);
  g_msg        varchar2(4000);
  g_stmt       varchar2(20);
  g_target     varchar2(261);
  g_hint       varchar2(261);
  g_res_target varchar2(261);
  g_owner      varchar2(128);
  g_use_dict   boolean := true;
  g_ctx        varchar2(10) := 'DATA';
  g_role       varchar2(20) := 'VALUE';

  g_refs       t_obj_refs;
  g_qb         t_qbs;
  g_src        t_srcs;
  g_item       t_items;
  g_cref       t_crefs;
  g_sq         t_sqs;
  g_cte        t_ctes;
  g_br         t_brs;
  g_outs       t_outs;
  g_qb_names   t_names_qb;
  g_tcols      t_names;
  g_top_qb     pls_integer;
  g_result     t_col_lins;
  g_dict       t_dict;

  s_stop   t_set;   -- clause keywords: end an expression
  s_oper   t_set;   -- keyword operators
  s_noise  t_set;   -- words that are never column names
  s_order  t_set;   -- ORDER BY modifiers
  s_win    t_set;   -- analytic clause words
  s_pseudo t_set;   -- pseudo columns / constants
  s_agg    t_set;   -- aggregate functions

  ------------------------------------------------------------------------------
  -- Forward declarations
  ------------------------------------------------------------------------------
  function parse_query (p_parent pls_integer, p_outer pls_integer) return pls_integer;
  function parse_expr  (p_parent pls_integer, p_qb pls_integer, p_clause varchar2,
                        p_item pls_integer, p_mode varchar2) return t_einfo;
  procedure parse_from_list (p_parent pls_integer, p_qb pls_integer);
  procedure parse_insert (p_parent pls_integer);
  procedure parse_update (p_parent pls_integer);
  procedure parse_delete (p_parent pls_integer);
  procedure parse_merge  (p_parent pls_integer);
  procedure compute_outputs (p_qb pls_integer);

  ------------------------------------------------------------------------------
  -- Utilities
  ------------------------------------------------------------------------------
  function norm_name (p_name in varchar2) return varchar2 is
  begin
    return upper(trim(replace(p_name, '"')));
  end norm_name;

  procedure note_partial (p_msg varchar2) is
  begin
    if g_status = 'OK' then g_status := 'PARTIAL'; end if;
    if g_msg is null then
      g_msg := substrb(p_msg, 1, 4000);
    elsif lengthb(g_msg) < 3800 then
      g_msg := substrb(g_msg || ' | ' || p_msg, 1, 4000);
    end if;
  end note_partial;

  -- character at absolute position i (buffered CLOB access)
  function ch (i pls_integer) return varchar2 is
  begin
    if i is null or i < 1 or i > g_len then return null; end if;
    if g_buf_start is null or i < g_buf_start or i >= g_buf_start + g_buf_len then
      g_buf       := dbms_lob.substr(g_sql, 8000, i);
      g_buf_start := i;
      g_buf_len   := nvl(length(g_buf), 0);
    end if;
    return substr(g_buf, i - g_buf_start + 1, 1);
  end ch;

  function raw_text (p_s pls_integer, p_e pls_integer) return varchar2 is
  begin
    if p_s is null or p_e is null or p_e < p_s then return null; end if;
    if g_buf_start is not null and p_s >= g_buf_start and p_e < g_buf_start + g_buf_len then
      return substr(g_buf, p_s - g_buf_start + 1, p_e - p_s + 1);
    end if;
    return dbms_lob.substr(g_sql, least(p_e - p_s + 1, 8000), p_s);
  end raw_text;

  -- source text of a range, whitespace collapsed, max 4000 bytes
  function src_text (p_s pls_integer, p_e pls_integer) return varchar2 is
    l varchar2(32767);
  begin
    if p_s is null or p_e is null or p_e < p_s then return null; end if;
    l := dbms_lob.substr(g_sql, least(p_e - p_s + 1, 8000), p_s);
    l := regexp_replace(l, '\s+', ' ');
    return substrb(l, 1, 4000);
  end src_text;

  function is_digit (c varchar2) return boolean is
  begin
    return c is not null and c between '0' and '9';
  end is_digit;

  function is_idch (c varchar2) return boolean is
  begin
    return c is not null
       and (instr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$#', c) > 0
            or (ascii(c) > 127 and c != unistr('\00A0')));
  end is_idch;

  ------------------------------------------------------------------------------
  -- Tokenizer
  ------------------------------------------------------------------------------
  procedure push_tok (p_type varchar2, p_s pls_integer, p_e pls_integer, p_txt varchar2 default null) is
    t t_tok;
  begin
    t.ttype := p_type;
    t.spos  := p_s;
    t.epos  := p_e;
    t.txt   := case when p_type = 'QID' then p_txt else raw_text(p_s, p_e) end;
    t.utxt  := case when p_type = 'QID' then p_txt else upper(t.txt) end;
    g_ntok := g_ntok + 1;
    g_tok(g_ntok) := t;
  end push_tok;

  procedure tokenize_all is
    i  pls_integer := 1;
    j  pls_integer;
    c  varchar2(8 char);
    c2 varchar2(8 char);
    q  varchar2(8 char);
    qe varchar2(8 char);
  begin
    g_tok.delete;
    g_ntok := 0;
    while i <= g_len loop
      c := ch(i);
      if c is null or c <= ' ' or c = unistr('\00A0') then
        i := i + 1;
      elsif c = '-' and ch(i + 1) = '-' then
        while i <= g_len and ch(i) != chr(10) loop i := i + 1; end loop;
      elsif c = '/' and ch(i + 1) = '*' then
        j := i + 2;
        while j < g_len and not (ch(j) = '*' and ch(j + 1) = '/') loop j := j + 1; end loop;
        i := j + 2;
      elsif c = ''''
         or (upper(c) in ('N', 'Q') and ch(i + 1) = '''')
         or (upper(c) = 'N' and upper(ch(i + 1)) = 'Q' and ch(i + 2) = '''') then
        j := i;
        if upper(c) = 'N' then j := j + 1; end if;           -- national prefix
        if upper(ch(j)) = 'Q' then                           -- q'<x> ... <x>'
          q  := ch(j + 2);
          qe := case q when '[' then ']' when '{' then '}' when '(' then ')' when '<' then '>' else q end;
          j  := j + 3;
          while j < g_len and not (ch(j) = qe and ch(j + 1) = '''') loop j := j + 1; end loop;
          j := j + 1;
        else
          j := j + 1;
          loop
            exit when j > g_len;
            if ch(j) = '''' then
              if ch(j + 1) = '''' then j := j + 2; else exit; end if;
            else
              j := j + 1;
            end if;
          end loop;
        end if;
        push_tok('STR', i, least(j, g_len));
        i := j + 1;
      elsif c = '"' then
        j := i + 1;
        loop
          exit when j > g_len;
          if ch(j) = '"' then
            if ch(j + 1) = '"' then j := j + 2; else exit; end if;
          else
            j := j + 1;
          end if;
        end loop;
        push_tok('QID', i, least(j, g_len), replace(raw_text(i + 1, j - 1), '""', '"'));
        i := j + 1;
      elsif is_digit(c) or (c = '.' and is_digit(ch(i + 1))) then
        j := i;
        while is_digit(ch(j)) loop j := j + 1; end loop;
        if ch(j) = '.' and nvl(ch(j + 1), ' ') != '.' then
          j := j + 1;
          while is_digit(ch(j)) loop j := j + 1; end loop;
        end if;
        if upper(ch(j)) = 'E' and (is_digit(ch(j + 1)) or (ch(j + 1) in ('+', '-') and is_digit(ch(j + 2)))) then
          j := j + 2;
          while is_digit(ch(j)) loop j := j + 1; end loop;
        end if;
        if upper(ch(j)) in ('F', 'D') and not is_idch(ch(j + 1)) then j := j + 1; end if;
        push_tok('NUM', i, j - 1);
        i := j;
      elsif is_idch(c) then
        j := i + 1;
        while is_idch(ch(j)) loop j := j + 1; end loop;
        push_tok('ID', i, j - 1);
        i := j;
      elsif c = ':' and is_idch(ch(i + 1)) then
        j := i + 1;
        while is_idch(ch(j)) loop j := j + 1; end loop;
        push_tok('BIND', i, j - 1);
        i := j;
      elsif c = '&' and (is_idch(ch(i + 1)) or ch(i + 1) = '&') then
        j := i + 1;
        if ch(j) = '&' then j := j + 1; end if;
        while is_idch(ch(j)) loop j := j + 1; end loop;
        if ch(j) = '.' then j := j + 1; end if;
        push_tok('BIND', i, j - 1);
        i := j;
      elsif c in ('(', ')', ',', ';', '.') then
        push_tok(c, i, i);
        i := i + 1;
      else
        c2 := c || ch(i + 1);
        if c2 in ('||', '<=', '>=', '<>', '!=', '^=', '=>', ':=', '**', '..') then
          push_tok('OP', i, i + 1);
          i := i + 2;
        else
          push_tok('OP', i, i);
          i := i + 1;
        end if;
      end if;
    end loop;
    g_eof.ttype := 'EOF';
    g_eof.txt   := null;
    g_eof.utxt  := null;
    g_eof.spos  := g_len + 1;
    g_eof.epos  := g_len + 1;
  end tokenize_all;

  ------------------------------------------------------------------------------
  -- Token cursor
  ------------------------------------------------------------------------------
  function tk (k pls_integer default 0) return t_tok is
  begin
    if g_p + k between 1 and g_ntok then return g_tok(g_p + k); end if;
    return g_eof;
  end tk;

  function tt (k pls_integer default 0) return varchar2 is
  begin
    if g_p + k between 1 and g_ntok then return g_tok(g_p + k).ttype; end if;
    return 'EOF';
  end tt;

  -- keyword view of a token: upper text for ID, punctuation/operator text, null otherwise
  function tu (k pls_integer default 0) return varchar2 is
  begin
    if g_p + k between 1 and g_ntok then
      if g_tok(g_p + k).ttype = 'ID' then
        return substr(g_tok(g_p + k).utxt, 1, 128);
      elsif g_tok(g_p + k).ttype in ('QID', 'STR', 'NUM', 'BIND') then
        return null;
      else
        return g_tok(g_p + k).txt;
      end if;
    end if;
    return null;
  end tu;

  procedure adv is
  begin
    if g_p <= g_ntok then g_p := g_p + 1; end if;
  end adv;

  function take (p_w varchar2) return boolean is
  begin
    if tu = p_w then adv; return true; end if;
    return false;
  end take;

  procedure need (p_w varchar2) is
  begin
    if not take(p_w) then
      note_partial('Expected ' || p_w || ' at char ' || tk().spos ||
                   case when tt != 'EOF' then ' (found ' || substr(tk().txt, 1, 30) || ')' end);
    end if;
  end need;

  function cur_spos return pls_integer is
  begin
    if g_p <= g_ntok then return g_tok(g_p).spos; end if;
    return g_len + 1;
  end cur_spos;

  function last_epos return pls_integer is
  begin
    if g_p > 1 then return g_tok(least(g_p - 1, g_ntok)).epos; end if;
    return 0;
  end last_epos;

  procedure skip_parens is
    d pls_integer := 0;
  begin
    if tt != '(' then return; end if;
    loop
      exit when tt = 'EOF';
      if tt = '(' then d := d + 1;
      elsif tt = ')' then d := d - 1;
      end if;
      adv;
      exit when d = 0;
    end loop;
  end skip_parens;

  -- skip to the end of the current clause (depth 0): ) ; EOF or a set operator
  procedure skip_clause is
  begin
    loop
      exit when tt in ('EOF', ';', ')')
             or tu in ('UNION', 'INTERSECT', 'MINUS', 'EXCEPT');
      if tt = '(' then skip_parens; else adv; end if;
    end loop;
  end skip_clause;

  ------------------------------------------------------------------------------
  -- AST
  ------------------------------------------------------------------------------
  function add_node (p_type varchar2, p_parent pls_integer, p_name varchar2 default null,
                     p_spos pls_integer default null, p_epos pls_integer default null)
    return pls_integer is
    n  t_ast_row;
    id pls_integer := g_ast.count + 1;
  begin
    n.node_id   := id;
    n.parent_id := p_parent;
    n.node_type := p_type;
    n.node_name := substrb(p_name, 1, 4000);
    n.start_pos := nvl(p_spos, cur_spos);
    n.end_pos   := p_epos;
    if p_parent is not null and g_ast.exists(p_parent) then
      n.depth := g_ast(p_parent).depth + 1;
      if g_kids.exists(p_parent) then
        g_kids(p_parent) := g_kids(p_parent) + 1;
      else
        g_kids(p_parent) := 1;
      end if;
      n.sibling_seq := g_kids(p_parent);
    else
      n.depth := 0;
      n.sibling_seq := 1;
    end if;
    g_ast(id) := n;
    return id;
  end add_node;

  procedure add_leaf (p_type varchar2, p_parent pls_integer, p_name varchar2 default null) is
    x pls_integer;
  begin
    x := add_node(p_type, p_parent, nvl(p_name, substr(tk().txt, 1, 4000)), tk().spos, tk().epos);
  end add_leaf;

  procedure close_node (p_id pls_integer) is
  begin
    if p_id is not null and g_ast.exists(p_id) then
      g_ast(p_id).end_pos := last_epos;
      if g_ast(p_id).end_pos < g_ast(p_id).start_pos then
        g_ast(p_id).end_pos := g_ast(p_id).start_pos - 1;
      end if;
    end if;
  end close_node;

  ------------------------------------------------------------------------------
  -- Registries
  ------------------------------------------------------------------------------
  function strip_owner (p_name varchar2) return varchar2 is
  begin
    if g_owner is not null and p_name like g_owner || '.%' then
      return substr(p_name, length(g_owner) + 2);
    end if;
    return p_name;
  end strip_owner;

  function last_part (p_name varchar2) return varchar2 is
  begin
    if instr(p_name, '.') > 0 then
      return substr(p_name, instr(p_name, '.', -1) + 1);
    end if;
    return p_name;
  end last_part;

  procedure add_ref (p_obj varchar2, p_role varchar2, p_ctx varchar2) is
    k pls_integer;
  begin
    if p_obj is null then return; end if;
    for i in 1 .. g_refs.count loop
      if g_refs(i).object_name = p_obj and g_refs(i).object_role = p_role
         and g_refs(i).ref_context = p_ctx then
        return;
      end if;
    end loop;
    k := g_refs.count + 1;
    g_refs(k).object_name := substr(p_obj, 1, 261);
    g_refs(k).object_role := p_role;
    g_refs(k).ref_context := p_ctx;
  end add_ref;

  function new_qb (p_kind varchar2, p_outer pls_integer) return pls_integer is
    id pls_integer := g_qb.count + 1;
  begin
    g_qb(id).kind     := p_kind;
    g_qb(id).outer_qb := p_outer;
    g_qb(id).out_done := false;
    g_qb(id).visiting := false;
    g_qb(id).out_cnt  := 0;
    return id;
  end new_qb;

  procedure add_src (p_qb pls_integer, p_alias varchar2, p_obj varchar2, p_dq pls_integer) is
    k pls_integer := g_src.count + 1;
  begin
    if p_qb is null then return; end if;
    g_src(k).qb    := p_qb;
    g_src(k).alias := p_alias;
    g_src(k).obj   := p_obj;
    g_src(k).dq    := p_dq;
  end add_src;

  procedure add_item (p_qb pls_integer, p_pos pls_integer, p_name varchar2, p_expr varchar2,
                      p_transform varchar2, p_star boolean default false,
                      p_star_qual varchar2 default null, p_agg_no_ref boolean default false) is
    k pls_integer := g_item.count + 1;
  begin
    g_item(k).qb         := p_qb;
    g_item(k).pos        := p_pos;
    g_item(k).name       := substr(p_name, 1, 128);
    g_item(k).expr       := substrb(p_expr, 1, 4000);
    g_item(k).transform  := p_transform;
    g_item(k).is_star    := p_star;
    g_item(k).star_qual  := p_star_qual;
    g_item(k).agg_no_ref := p_agg_no_ref;
  end add_item;

  procedure add_cref (p_qb pls_integer, p_item pls_integer, p_clause varchar2,
                      p_qual varchar2, p_col varchar2) is
    k pls_integer := g_cref.count + 1;
  begin
    if p_qb is null then return; end if;
    g_cref(k).qb       := p_qb;
    g_cref(k).item_pos := p_item;
    g_cref(k).clause   := p_clause;
    g_cref(k).qual     := p_qual;
    g_cref(k).col      := substr(p_col, 1, 128);
    g_cref(k).role     := g_role;
  end add_cref;

  procedure add_sq (p_qb pls_integer, p_item pls_integer, p_sq pls_integer, p_sq_pos pls_integer) is
    k pls_integer := g_sq.count + 1;
  begin
    if p_qb is null or p_item is null or p_sq is null then return; end if;
    g_sq(k).qb       := p_qb;
    g_sq(k).item_pos := p_item;
    g_sq(k).sq       := p_sq;
    g_sq(k).sq_pos   := p_sq_pos;
  end add_sq;

  function find_cte (p_name varchar2) return pls_integer is
  begin
    for i in reverse 1 .. g_cte.count loop
      if g_cte(i).name = p_name then return i; end if;
    end loop;
    return null;
  end find_cte;

  ------------------------------------------------------------------------------
  -- Names
  ------------------------------------------------------------------------------
  -- ID/QID ( . ID/QID )* [ @dblink ]
  function read_name return varchar2 is
    l varchar2(4000);
  begin
    if tt not in ('ID', 'QID') then return null; end if;
    l := tk().utxt;
    adv;
    while tt = '.' and tt(1) in ('ID', 'QID') loop
      adv;
      l := l || '.' || tk().utxt;
      adv;
    end loop;
    if tu = '@' then
      adv;
      l := l || '@';
      while tt in ('ID', 'QID', '.') loop
        l := l || case when tt = '.' then '.' else tk().utxt end;
        adv;
      end loop;
    end if;
    return substr(l, 1, 261);
  end read_name;

  function is_alias_tok (k pls_integer default 0) return boolean is
  begin
    return tt(k) = 'QID'
        or (tt(k) = 'ID'
            and not s_stop.exists(tu(k))
            and not s_oper.exists(tu(k))
            and tu(k) not in ('PIVOT', 'UNPIVOT', 'PARTITION', 'SUBPARTITION', 'SAMPLE',
                              'LATERAL', 'APPLY', 'MATCHED', 'NOCYCLE'));
  end is_alias_tok;

  function read_alias return varchar2 is
    a varchar2(261);
  begin
    if tu = 'AS' and is_alias_tok(1) then adv; end if;
    if is_alias_tok then
      a := tk().utxt;
      adv;
    end if;
    return a;
  end read_alias;

  -- (c1, t.c2, "c3")  -> names (last part of each entry)
  function read_col_list return t_names is
    l t_names;
  begin
    if tt != '(' then return l; end if;
    adv;
    loop
      exit when tt in (')', 'EOF', ';');
      if tt in ('ID', 'QID') and tt(1) != '.' then
        l(l.count + 1) := substr(tk().utxt, 1, 128);
      end if;
      if tt = '(' then skip_parens; else adv; end if;
    end loop;
    need(')');
    return l;
  end read_col_list;

  ------------------------------------------------------------------------------
  -- Expressions
  ------------------------------------------------------------------------------
  procedure merge_info (a in out nocopy t_einfo, b t_einfo) is
  begin
    a.n_refs   := a.n_refs + b.n_refs;
    a.has_agg  := a.has_agg  or b.has_agg;
    a.has_win  := a.has_win  or b.has_win;
    a.has_case := a.has_case or b.has_case;
    a.has_subq := a.has_subq or b.has_subq;
  end merge_info;

  function item_transform (e t_einfo, p_name varchar2) return varchar2 is
  begin
    if e.has_win then return 'WINDOW';
    elsif e.has_agg then return 'AGGREGATE';
    elsif e.has_case then return 'CASE';
    elsif e.atoms = 1 and e.simple_col is not null then
      return case when p_name is null or p_name = e.simple_col then 'DIRECT' else 'RENAME' end;
    elsif e.n_refs = 0 and not e.has_subq then return 'CONSTANT';
    else return 'CALCULATED';
    end if;
  end item_transform;

  function expr_text (p_node pls_integer) return varchar2 is
  begin
    return src_text(g_ast(p_node).start_pos, g_ast(p_node).end_pos);
  end expr_text;

  function parse_subquery_paren (p_parent pls_integer, p_outer pls_integer) return pls_integer is
    n  pls_integer;
    sq pls_integer;
  begin
    n := add_node('SUBQUERY', p_parent);
    adv;                                   -- (
    sq := parse_query(n, p_outer);
    need(')');
    close_node(n);
    return sq;
  end parse_subquery_paren;

  -- OVER (...), WITHIN GROUP (...), KEEP (...)
  procedure parse_window_body (p_parent pls_integer, p_qb pls_integer, p_clause varchar2,
                               p_item pls_integer, p_kind varchar2) is
    w     pls_integer;
    sub   t_einfo;
    guard pls_integer;
    sv    varchar2(20) := g_role;
  begin
    if tt != '(' then return; end if;
    w := add_node(p_kind, p_parent);
    adv;
    if sv = 'VALUE' then g_role := 'WINDOW'; end if;
    loop
      guard := g_p;
      exit when tt in (')', 'EOF', ';');
      sub := parse_expr(w, p_qb, p_clause, p_item, 'WIN');
      if tt = ',' then adv; end if;
      if g_p = guard then adv; end if;
    end loop;
    g_role := sv;
    need(')');
    close_node(w);
  end parse_window_body;

  function parse_function (p_parent pls_integer, p_qb pls_integer, p_clause varchar2,
                           p_item pls_integer, p_name varchar2, p_spos pls_integer)
    return t_einfo is
    e      t_einfo;
    sub    t_einfo;
    f      pls_integer;
    sq     pls_integer;
    guard  pls_integer;
    u      varchar2(261) := upper(last_part(p_name));
    is_agg boolean;
  begin
    f := add_node('FUNCTION', p_parent, p_name, p_spos);
    e.node := f;
    is_agg := s_agg.exists(substr(u, 1, 128)) and instr(p_name, '.') = 0;
    if u = 'DECODE' then e.has_case := true; end if;
    adv;                                   -- (
    if tu in ('SELECT', 'WITH') then
      sq := parse_query(f, p_qb);
      add_sq(p_qb, p_item, sq, 1);
      e.has_subq := true;
    else
      if u = 'EXTRACT' and tt = 'ID' then adv; end if;   -- datetime field
      if u in ('VALUE', 'REF', 'DEREF') and tt in ('ID', 'QID') and tt(1) = ')' then
        -- VALUE(t): the row of table alias t (TABLE() collections expose COLUMN_VALUE)
        add_leaf('COLUMN_REF', f, tk().utxt || '.COLUMN_VALUE');
        add_cref(p_qb, p_item, p_clause, tk().utxt, 'COLUMN_VALUE');
        e.n_refs := e.n_refs + 1;
        adv;
      end if;
      if u = 'XMLELEMENT' then                            -- XMLELEMENT([NAME] tag, ...)
        if tu in ('NAME', 'EVALNAME') and tt(1) in ('ID', 'QID') then adv; end if;
        if tt in ('ID', 'QID') and tt(1) in (',', ')') then adv; end if;
      end if;
      loop
        guard := g_p;
        exit when tt in (')', 'EOF', ';');
        sub := parse_expr(f, p_qb, p_clause, p_item, 'ARG');
        merge_info(e, sub);
        if tt = ',' then adv; end if;
        if g_p = guard then adv; end if;
      end loop;
    end if;
    need(')');
    if tu in ('IGNORE', 'RESPECT') and tu(1) = 'NULLS' then adv; adv; end if;
    if tu = 'WITHIN' and tu(1) = 'GROUP' then
      adv; adv;
      parse_window_body(f, p_qb, p_clause, p_item, 'WITHIN_GROUP');
    end if;
    if tu = 'KEEP' and tt(1) = '(' then
      adv;
      parse_window_body(f, p_qb, p_clause, p_item, 'KEEP');
    end if;
    if tu in ('IGNORE', 'RESPECT') and tu(1) = 'NULLS' then adv; adv; end if;
    if tu = 'OVER' then
      adv;
      e.has_win := true;
      if tt = '(' then
        parse_window_body(f, p_qb, p_clause, p_item, 'WINDOW');
      elsif tt in ('ID', 'QID') then
        adv;
      end if;
    elsif is_agg then
      e.has_agg := true;
    end if;
    close_node(f);
    return e;
  end parse_function;

  function parse_case (p_parent pls_integer, p_qb pls_integer, p_clause varchar2,
                       p_item pls_integer) return t_einfo is
    e     t_einfo;
    sub   t_einfo;
    c     pls_integer;
    w     pls_integer;
    guard pls_integer;
    sv    varchar2(20) := g_role;
  begin
    c := add_node('CASE', p_parent);
    e.node := c;
    e.has_case := true;
    adv;                                   -- CASE
    if tu != 'WHEN' or tu is null then     -- simple CASE operand
      if sv = 'VALUE' then g_role := 'CONDITION'; end if;
      w := add_node('CASE_OPERAND', c);
      sub := parse_expr(w, p_qb, p_clause, p_item, 'CASE');
      merge_info(e, sub);
      close_node(w);
      g_role := sv;
    end if;
    loop
      guard := g_p;
      if tu = 'WHEN' then
        adv;
        if sv = 'VALUE' then g_role := 'CONDITION'; end if;
        w := add_node('WHEN', c);
        sub := parse_expr(w, p_qb, p_clause, p_item, 'CASE');
        merge_info(e, sub);
        close_node(w);
        g_role := sv;
        if take('THEN') then
          w := add_node('THEN', c);
          sub := parse_expr(w, p_qb, p_clause, p_item, 'CASE');
          merge_info(e, sub);
          close_node(w);
        end if;
      elsif tu = 'ELSE' then
        adv;
        w := add_node('ELSE', c);
        sub := parse_expr(w, p_qb, p_clause, p_item, 'CASE');
        merge_info(e, sub);
        close_node(w);
      elsif tu = 'END' then
        adv;
        exit;
      elsif tt in ('EOF', ';', ')') then
        note_partial('Unterminated CASE at char ' || g_ast(c).start_pos);
        exit;
      else
        adv;
      end if;
      if g_p = guard then adv; end if;
    end loop;
    g_role := sv;
    close_node(c);
    return e;
  end parse_case;

  --
  -- Generic, fault tolerant expression parser.
  --   p_mode : ITEM (select item, stops before alias) / COND / ARG (inside parens)
  --            LIST (group/order by) / WIN (analytic clause) / SET / CASE
  --
  function parse_expr (p_parent pls_integer, p_qb pls_integer, p_clause varchar2,
                       p_item pls_integer, p_mode varchar2) return t_einfo is
    e       t_einfo;
    sub     t_einfo;
    n       pls_integer;
    leaf    pls_integer;
    sq      pls_integer;
    guard   pls_integer;
    t       t_tok;
    u       varchar2(128);
    prev_op boolean := false;     -- previous atom was an operand
    parts   t_names;
    np      pls_integer;
    spos    pls_integer;
    nm      varchar2(4000);
    qual    varchar2(4000);
    d       pls_integer;
  begin
    n := add_node('EXPR', p_parent);
    e.node := n;
    loop
      guard := g_p;
      t := tk();
      u := tu;
      exit when t.ttype in ('EOF', ';', ',', ')');

      -- mode specific noise words
      if t.ttype = 'ID' and (
           (p_mode = 'WIN' and (s_win.exists(u) or s_order.exists(u)))
        or (p_mode = 'LIST' and s_order.exists(u))
        or s_noise.exists(u)) then
        add_leaf('KEYWORD', n);
        adv;
        continue;
      end if;

      -- clause keywords end the expression (inside parens they are noise)
      if t.ttype = 'ID' and s_stop.exists(u)
         and not (tt(1) = '(' and u in ('LOG', 'LEFT', 'RIGHT')) then
        if p_mode in ('ARG', 'WIN') and u not in ('WHEN', 'THEN', 'ELSE', 'END') then
          if u = 'AS' then                 -- CAST(x AS type)
            adv;
            d := 0;
            loop
              exit when tt in ('EOF', ';') or (d = 0 and tt in (',', ')'));
              if tt = '(' then d := d + 1; elsif tt = ')' then d := d - 1; end if;
              adv;
            end loop;
          else
            add_leaf('KEYWORD', n);
            adv;
            prev_op := false;
          end if;
          continue;
        end if;
        exit;
      end if;

      -- alias follows the expression
      if p_mode = 'ITEM' and prev_op
         and (t.ttype = 'QID' or (t.ttype = 'ID' and not s_oper.exists(u))) then
        exit;
      end if;

      if t.ttype = '(' then
        if tu(1) in ('SELECT', 'WITH') then
          sq := parse_subquery_paren(n, p_qb);
          add_sq(p_qb, p_item, sq, 1);
          e.has_subq := true;
          e.atoms := e.atoms + 1;
          prev_op := true;
        elsif tu(1) = '+' and tt(2) = ')' then      -- (+) outer join marker
          adv; adv; adv;
        else
          leaf := add_node('PAREN', n);
          adv;
          loop
            exit when tt in (')', 'EOF', ';');
            sub := parse_expr(leaf, p_qb, p_clause, p_item,
                              case when p_mode = 'WIN' then 'WIN' else 'ARG' end);
            merge_info(e, sub);
            if tt = ',' then adv;
            elsif tt not in (')', 'EOF', ';') then adv;
            end if;
          end loop;
          need(')');
          close_node(leaf);
          e.atoms := e.atoms + 1;
          prev_op := true;
        end if;

      elsif t.ttype = 'ID' and u = 'CASE' then
        sub := parse_case(n, p_qb, p_clause, p_item);
        merge_info(e, sub);
        e.atoms := e.atoms + 1;
        prev_op := true;

      elsif t.ttype = 'ID' and u in ('DATE', 'TIMESTAMP') and tt(1) = 'STR' then
        leaf := add_node('LITERAL', n, null, t.spos, tk(1).epos);
        adv; adv;
        e.atoms := e.atoms + 1;
        prev_op := true;

      elsif t.ttype = 'ID' and u = 'INTERVAL' and tt(1) = 'STR' then
        leaf := add_node('LITERAL', n, null, t.spos);
        adv; adv;
        while tu in ('YEAR', 'MONTH', 'DAY', 'HOUR', 'MINUTE', 'SECOND', 'TO') loop
          adv;
          if tt = '(' then skip_parens; end if;
        end loop;
        close_node(leaf);
        e.atoms := e.atoms + 1;
        prev_op := true;

      elsif t.ttype = 'ID' and s_oper.exists(u) then
        add_leaf('OPERATOR', n, u);
        adv;
        e.atoms := e.atoms + 1;
        prev_op := false;

      elsif t.ttype = 'ID' and s_pseudo.exists(u) and tt(1) not in ('(', '.') then
        add_leaf('PSEUDO_COLUMN', n, u);
        adv;
        e.atoms := e.atoms + 1;
        prev_op := true;

      elsif t.ttype in ('ID', 'QID') then
        spos := t.spos;
        parts.delete;
        np := 0;
        loop
          np := np + 1;
          parts(np) := substr(tk().utxt, 1, 128);
          adv;
          exit when not (tt = '.' and (tt(1) in ('ID', 'QID') or tu(1) = '*'));
          adv;                             -- .
          if tu = '*' then
            np := np + 1;
            parts(np) := '*';
            adv;
            exit;
          end if;
        end loop;
        nm := parts(1);
        for k in 2 .. np loop nm := nm || '.' || parts(k); end loop;
        qual := null;
        for k in 1 .. np - 1 loop
          qual := case when qual is null then parts(k) else qual || '.' || parts(k) end;
        end loop;

        if tt = '(' and tu(1) = '+' and tt(2) = ')' then
          leaf := add_node('COLUMN_REF', n, nm, spos, last_epos);
          add_cref(p_qb, p_item, p_clause, qual, parts(np));
          adv; adv; adv;
          e.n_refs := e.n_refs + 1;
          e.simple_col := parts(np);
        elsif tt = '(' then
          sub := parse_function(n, p_qb, p_clause, p_item, nm, spos);
          merge_info(e, sub);
        elsif np > 1 and parts(np) in ('NEXTVAL', 'CURRVAL') then
          leaf := add_node('SEQUENCE', n, nm, spos, last_epos);
        elsif parts(np) = '*' then
          leaf := add_node('STAR', n, nm, spos, last_epos);
        else
          leaf := add_node('COLUMN_REF', n, nm, spos, last_epos);
          add_cref(p_qb, p_item, p_clause, qual, parts(np));
          e.n_refs := e.n_refs + 1;
          e.simple_col := parts(np);
        end if;
        e.atoms := e.atoms + 1;
        prev_op := true;

      elsif t.ttype = '.' and prev_op and tt(1) in ('ID', 'QID') then
        -- method call / attribute on an expression: XMLAGG(...).EXTRACT('//text()'),
        -- XMLTYPE(x).getStringVal(), (obj).attr
        adv;                               -- .
        spos := tk().spos;
        nm := '.' || tk().utxt;
        adv;
        if tt = '(' then
          sub := parse_function(n, p_qb, p_clause, p_item, nm, spos);
          merge_info(e, sub);
        else
          leaf := add_node('ATTRIBUTE', n, nm, spos, last_epos);
        end if;
        prev_op := true;

      elsif t.ttype in ('STR', 'NUM', 'BIND') then
        add_leaf(case t.ttype when 'BIND' then 'BIND' else 'LITERAL' end, n);
        adv;
        e.atoms := e.atoms + 1;
        prev_op := true;

      elsif t.ttype = 'OP' then
        if u = '*' and not prev_op then
          add_leaf('STAR', n);
          prev_op := true;
        else
          add_leaf('OPERATOR', n);
          prev_op := false;
        end if;
        adv;
        e.atoms := e.atoms + 1;

      else
        adv;
      end if;

      if g_p = guard then adv; end if;
    end loop;
    close_node(n);
    if e.atoms != 1 then e.simple_col := null; end if;
    return e;
  end parse_expr;

  procedure parse_expr_list (p_parent pls_integer, p_qb pls_integer, p_clause varchar2, p_mode varchar2) is
    e t_einfo;
  begin
    loop
      e := parse_expr(p_parent, p_qb, p_clause, null, p_mode);
      exit when not take(',');
    end loop;
  end parse_expr_list;

  ------------------------------------------------------------------------------
  -- FROM clause
  ------------------------------------------------------------------------------
  procedure parse_from_item (p_parent pls_integer, p_qb pls_integer) is
    t     pls_integer;
    dq    pls_integer;
    ci    pls_integer;
    nsrc  pls_integer;
    nm    varchar2(261);
    alias varchar2(261);
    spos  pls_integer;
    e     t_einfo;
  begin
    if tt = '(' and tu(1) in ('SELECT', 'WITH') then
      t := add_node('DERIVED_TABLE', p_parent);
      adv;
      dq := parse_query(t, g_qb(p_qb).outer_qb);
      need(')');
      alias := read_alias;
      g_ast(t).node_name := alias;
      add_src(p_qb, alias, null, dq);
    elsif tt = '(' then                      -- ( a JOIN b ON ... )  or  ( (subquery) ) alias
      t := add_node('JOIN_GROUP', p_parent);
      adv;
      nsrc := g_src.count;
      parse_from_list(t, p_qb);
      need(')');
      alias := read_alias;
      -- a single table / subquery wrapped in extra parentheses takes the outer alias:
      --   FROM ( (select ... from x) ) dlst
      if alias is not null then
        dq := null;                        -- reused: index of the single source at this level
        for i in nsrc + 1 .. g_src.count loop
          if g_src(i).qb = p_qb then
            if dq is null then dq := i; else dq := -1; end if;
          end if;
        end loop;
        if dq > 0 then g_src(dq).alias := alias; end if;
      end if;
    elsif tu = 'LATERAL' and tt(1) = '(' then
      t := add_node('DERIVED_TABLE', p_parent, 'LATERAL');
      adv; adv;
      dq := parse_query(t, p_qb);
      need(')');
      alias := read_alias;
      add_src(p_qb, alias, null, dq);
    elsif tu in ('TABLE', 'XMLTABLE', 'JSON_TABLE', 'THE') and tt(1) = '(' then
      -- collection / table function: its rows expose COLUMN_VALUE, computed from
      -- the expression inside the parentheses (which may reference earlier FROM items)
      t := add_node('TABLE_FUNCTION', p_parent, tu);
      adv;                                 -- TABLE
      adv;                                 -- (
      dq := new_qb('TFUNC', p_qb);
      e := parse_expr(t, dq, 'SELECT', 1, 'ARG');
      while tt = ',' loop                  -- XMLTABLE / JSON_TABLE extra arguments
        adv;
        e := parse_expr(t, dq, 'SELECT', 1, 'ARG');
      end loop;
      need(')');
      add_item(dq, 1, 'COLUMN_VALUE', src_text(g_ast(t).start_pos, last_epos), 'CALCULATED');
      alias := read_alias;
      add_src(p_qb, alias, null, dq);
    elsif tt in ('ID', 'QID') then
      spos := cur_spos;
      nm := read_name;
      ci := find_cte(nm);
      if ci is not null then
        t := add_node('CTE_REF', p_parent, nm, spos, last_epos);
        alias := read_alias;
        add_src(p_qb, nvl(alias, nm), null, g_cte(ci).qb);
        g_src(g_src.count).cte := ci;      -- recursive CTE: linked once its definition is parsed
      else
        nm := strip_owner(nm);
        t := add_node('TABLE_REF', p_parent, nm, spos, last_epos);
        add_ref(nm, 'SOURCE', g_ctx);
        if tu in ('PARTITION', 'SUBPARTITION') and tt(1) = '(' then adv; skip_parens; end if;
        if tu = 'SAMPLE' then
          adv;
          if tu = 'BLOCK' then adv; end if;
          skip_parens;
          if tu = 'SEED' then adv; skip_parens; end if;
        end if;
        alias := read_alias;
        add_src(p_qb, alias, nm, null);
      end if;
    else
      return;
    end if;
    if tu in ('PIVOT', 'UNPIVOT') then
      adv;
      if tu in ('INCLUDE', 'EXCLUDE') then adv; adv; end if;
      if tu = 'XML' then adv; end if;
      skip_parens;
      alias := nvl(read_alias, alias);
    end if;
    if alias is not null then
      g_ast(t).node_name := substrb(g_ast(t).node_name || ' ' || alias, 1, 4000);
    end if;
    close_node(t);
  end parse_from_item;

  procedure parse_from_list (p_parent pls_integer, p_qb pls_integer) is
    j     pls_integer;
    o     pls_integer;
    jt    varchar2(100);
    e     t_einfo;
    guard pls_integer;
  begin
    parse_from_item(p_parent, p_qb);
    loop
      guard := g_p;
      if tt = ',' then
        adv;
        parse_from_item(p_parent, p_qb);
      elsif tu in ('JOIN', 'INNER', 'LEFT', 'RIGHT', 'FULL', 'CROSS', 'NATURAL')
         or (tu = 'OUTER' and tu(1) = 'APPLY') then
        jt := null;
        while tu in ('NATURAL', 'INNER', 'LEFT', 'RIGHT', 'FULL', 'OUTER', 'CROSS') loop
          jt := jt || tu || ' ';
          adv;
        end loop;
        if tu in ('JOIN', 'APPLY') then
          jt := jt || tu;
          adv;
        end if;
        j := add_node('JOIN', p_parent, trim(jt));
        parse_from_item(j, p_qb);
        if tu = 'ON' then
          adv;
          o := add_node('ON', j);
          e := parse_expr(o, p_qb, 'ON', null, 'COND');
          close_node(o);
        elsif tu = 'USING' then
          adv;
          skip_parens;
        end if;
        close_node(j);
      elsif tt in (')', ';', 'EOF')
         or nvl(tu, '~') in ('WHERE', 'GROUP', 'HAVING', 'ORDER', 'CONNECT', 'START', 'UNION',
                             'INTERSECT', 'MINUS', 'EXCEPT', 'MODEL', 'WINDOW', 'FETCH', 'OFFSET',
                             'FOR', 'ON', 'USING', 'WHEN', 'SET', 'VALUES', 'RETURNING', 'LOG',
                             'WITH', 'SELECT', 'QUALIFY') then
        exit;
      else
        -- unsupported syntax inside FROM: skip it, keep the following tables
        note_partial('Skipped unsupported FROM syntax at char ' || cur_spos || ': '
                     || substr(tk().txt, 1, 40));
        loop
          exit when tt in (',', ')', ';', 'EOF')
                 or nvl(tu, '~') in ('JOIN', 'INNER', 'LEFT', 'RIGHT', 'FULL', 'CROSS', 'NATURAL',
                                     'WHERE', 'GROUP', 'HAVING', 'ORDER', 'CONNECT', 'START',
                                     'UNION', 'INTERSECT', 'MINUS', 'EXCEPT');
          if tt = '(' then skip_parens; else adv; end if;
        end loop;
      end if;
      exit when g_p = guard;
    end loop;
  end parse_from_list;

  ------------------------------------------------------------------------------
  -- SELECT
  ------------------------------------------------------------------------------
  procedure parse_select_item (p_list pls_integer, p_qb pls_integer, p_pos pls_integer) is
    it    pls_integer;
    e     t_einfo;
    alias varchar2(261);
    nm    varchar2(261);
    qual  varchar2(261);
  begin
    it := add_node('SELECT_ITEM', p_list);
    if tu = '*' then
      add_leaf('STAR', it);
      adv;
      nm := '*';
      add_item(p_qb, p_pos, '*', '*', 'STAR', true, null);
    elsif tt in ('ID', 'QID') and tt(1) = '.' and tu(2) = '*' then
      qual := tk().utxt;
      nm := qual || '.*';
      add_leaf('STAR', it, nm);
      adv; adv; adv;
      add_item(p_qb, p_pos, '*', nm, 'STAR', true, qual);
    elsif tt in ('ID', 'QID') and tt(1) = '.' and tt(2) in ('ID', 'QID') and tt(3) = '.' and tu(4) = '*' then
      qual := tk().utxt || '.' || tk(2).utxt;
      nm := qual || '.*';
      add_leaf('STAR', it, nm);
      adv; adv; adv; adv; adv;
      add_item(p_qb, p_pos, '*', nm, 'STAR', true, strip_owner(qual));
    else
      e := parse_expr(it, p_qb, 'SELECT', p_pos, 'ITEM');
      if tu = 'AS' then
        adv;
        if tt in ('ID', 'QID') then
          alias := tk().utxt;
          add_leaf('ALIAS', it, alias);
          adv;
        end if;
      elsif tt = 'QID' or (tt = 'ID' and not s_stop.exists(tu) and not s_oper.exists(tu)) then
        alias := tk().utxt;
        add_leaf('ALIAS', it, alias);
        adv;
      end if;
      -- Oracle names an unaliased expression after its text: SUM(LOCAL_AMOUNT)
      nm := substr(coalesce(alias, e.simple_col,
                            upper(replace(expr_text(e.node), ' ')), 'EXPR$' || p_pos), 1, 128);
      add_item(p_qb, p_pos, nm, expr_text(e.node), item_transform(e, nm), false, null,
               e.has_agg and e.n_refs = 0);
    end if;
    close_node(it);
    g_ast(it).node_name := nm;
  end parse_select_item;

  function parse_select_block (p_parent pls_integer, p_outer pls_integer) return pls_integer is
    qb    pls_integer := new_qb('SELECT', p_outer);
    n     pls_integer;
    lst   pls_integer;
    c     pls_integer;
    pos   pls_integer := 0;
    sv    varchar2(10);
    guard pls_integer;
    e     t_einfo;
  begin
    n := add_node('SELECT', p_parent);
    adv;                                   -- SELECT
    if tu in ('DISTINCT', 'UNIQUE', 'ALL') then add_leaf('KEYWORD', n); adv; end if;
    lst := add_node('SELECT_LIST', n);
    loop
      pos := pos + 1;
      begin
        parse_select_item(lst, qb, pos);
      exception
        when others then
          g_role := 'VALUE';
          note_partial('Select item ' || pos || ' near char ' || cur_spos || ': ' || sqlerrm);
      end;
      -- anything other than ',' / FROM here is a construct the parser did not
      -- understand: skip to the end of this item and keep going
      if tt not in (',', ')', ';', 'EOF')
         and nvl(tu, '~') not in ('FROM', 'INTO', 'BULK', 'UNION', 'INTERSECT', 'MINUS', 'EXCEPT',
                                  'WHERE', 'GROUP', 'ORDER', 'FETCH', 'OFFSET') then
        note_partial('Skipped unsupported syntax in select item ' || pos || ' at char ' || cur_spos
                     || ': ' || substr(tk().txt, 1, 40));
        loop
          exit when tt in (',', ')', ';', 'EOF')
                 or nvl(tu, '~') in ('FROM', 'INTO', 'BULK', 'UNION', 'INTERSECT', 'MINUS', 'EXCEPT');
          if tt = '(' then skip_parens; else adv; end if;
        end loop;
      end if;
      exit when not take(',');
    end loop;
    close_node(lst);
    if tu = 'BULK' then adv; adv; end if;
    if tu = 'INTO' then                    -- PL/SQL SELECT ... INTO
      loop
        exit when tt in ('EOF', ';') or tu = 'FROM';
        adv;
      end loop;
    end if;
    if tu = 'FROM' then
      c := add_node('FROM', n);
      adv;
      parse_from_list(c, qb);
      close_node(c);
    end if;
    loop
      guard := g_p;
      if tu = 'WHERE' then
        c := add_node('WHERE', n);
        adv;
        sv := g_ctx; g_ctx := 'FILTER';
        e := parse_expr(c, qb, 'WHERE', null, 'COND');
        g_ctx := sv;
        close_node(c);
      elsif tu in ('START', 'CONNECT') then
        c := add_node('HIERARCHY', n);
        adv;
        if tu in ('WITH', 'BY') then adv; end if;
        if tu = 'NOCYCLE' then adv; end if;
        sv := g_ctx; g_ctx := 'FILTER';
        e := parse_expr(c, qb, 'CONNECT', null, 'COND');
        g_ctx := sv;
        close_node(c);
      elsif tu = 'GROUP' and tu(1) = 'BY' then
        c := add_node('GROUP_BY', n);
        adv; adv;
        if tu = 'GROUPING' and tu(1) = 'SETS' then adv; adv; end if;
        parse_expr_list(c, qb, 'GROUP', 'LIST');
        close_node(c);
      elsif tu = 'HAVING' then
        c := add_node('HAVING', n);
        adv;
        sv := g_ctx; g_ctx := 'FILTER';
        e := parse_expr(c, qb, 'HAVING', null, 'COND');
        g_ctx := sv;
        close_node(c);
      elsif tu in ('MODEL', 'WINDOW', 'QUALIFY') then
        c := add_node(tu, n);
        adv;
        skip_clause;
        close_node(c);
      else
        exit;
      end if;
      exit when g_p = guard;
    end loop;
    close_node(n);
    return qb;
  end parse_select_block;

  function parse_query_term (p_parent pls_integer, p_outer pls_integer) return pls_integer is
    n  pls_integer;
    qb pls_integer;
  begin
    if tt = '(' then
      n := add_node('SUBQUERY', p_parent);
      adv;
      qb := parse_query(n, p_outer);
      need(')');
      close_node(n);
      return qb;
    elsif tu = 'SELECT' then
      return parse_select_block(p_parent, p_outer);
    elsif tu = 'WITH' then
      return parse_query(p_parent, p_outer);
    end if;
    note_partial('SELECT expected at char ' || cur_spos);
    return new_qb('SELECT', p_outer);
  end parse_query_term;

  procedure parse_with (p_parent pls_integer, p_outer pls_integer) is
    w     pls_integer;
    c     pls_integer;
    ci    pls_integer;
    cq    pls_integer;
    nm    varchar2(128);
    names t_names;
  begin
    w := add_node('WITH', p_parent);
    adv;                                   -- WITH
    if tu = 'RECURSIVE' then adv; end if;
    if tu in ('FUNCTION', 'PROCEDURE') then  -- 12c inline PL/SQL declarations
      loop
        exit when tt = 'EOF' or (tu = 'SELECT') ;
        adv;
      end loop;
      close_node(w);
      return;
    end if;
    loop
      exit when tt not in ('ID', 'QID');
      nm := substr(tk().utxt, 1, 128);
      c := add_node('CTE', w, nm);
      adv;
      ci := g_cte.count + 1;
      g_cte(ci).name := nm;
      g_cte(ci).qb := null;
      names := read_col_list;
      need('AS');
      if tt = '(' then
        adv;
        cq := parse_query(c, p_outer);
        need(')');
        g_cte(ci).qb := cq;
        for i in 1 .. g_src.count loop       -- self references inside a recursive CTE
          if g_src(i).cte = ci and g_src(i).dq is null then g_src(i).dq := cq; end if;
        end loop;
        if names.count > 0 then g_qb_names(cq) := names; end if;
      end if;
      if tu in ('SEARCH', 'CYCLE') then
        loop
          exit when tt in (',', 'EOF', ';') or tu = 'SELECT';
          if tt = '(' then skip_parens; else adv; end if;
        end loop;
      end if;
      close_node(c);
      exit when not take(',');
    end loop;
    close_node(w);
  end parse_with;

  function parse_query (p_parent pls_integer, p_outer pls_integer) return pls_integer is
    n        pls_integer;
    o        pls_integer;
    first_qb pls_integer;
    so       pls_integer;
    b        pls_integer;
    k        pls_integer;
    res      pls_integer;
    op       varchar2(30);
  begin
    n := add_node('QUERY', p_parent);
    if tu = 'WITH' then parse_with(n, p_outer); end if;
    first_qb := parse_query_term(n, p_outer);
    res := first_qb;
    if tu in ('UNION', 'INTERSECT', 'MINUS', 'EXCEPT') then
      so := new_qb('SETOP', p_outer);
      k := g_br.count + 1; g_br(k).setop := so; g_br(k).br := first_qb;
      while tu in ('UNION', 'INTERSECT', 'MINUS', 'EXCEPT') loop
        op := tu;
        add_leaf('SET_OP', n, op);
        adv;
        if tu in ('ALL', 'DISTINCT') then
          g_ast(g_ast.count).node_name := op || ' ' || tu;
          adv;
        end if;
        b := parse_query_term(n, p_outer);
        k := g_br.count + 1; g_br(k).setop := so; g_br(k).br := b;
      end loop;
      res := so;
    end if;
    if tu = 'ORDER' and tu(1) = 'BY' then
      o := add_node('ORDER_BY', n);
      adv; adv;
      if tu = 'SIBLINGS' then adv; end if;
      parse_expr_list(o, first_qb, 'ORDER', 'LIST');
      close_node(o);
    end if;
    if tu in ('OFFSET', 'FETCH') then
      o := add_node('ROW_LIMIT', n);
      skip_clause;
      close_node(o);
    end if;
    if tu = 'FOR' and tu(1) = 'UPDATE' then
      skip_clause;
    end if;
    close_node(n);
    return res;
  end parse_query;

  ------------------------------------------------------------------------------
  -- DML / DDL / PL/SQL
  ------------------------------------------------------------------------------
  procedure parse_insert (p_parent pls_integer) is
    i     pls_integer;
    t     pls_integer;
    v     pls_integer;
    vqb   pls_integer;
    pos   pls_integer := 0;
    nm    varchar2(261);
    alias varchar2(261);
    e     t_einfo;
    qb    pls_integer;
    spos  pls_integer;
  begin
    i := add_node('INSERT', p_parent);
    adv;                                   -- INSERT
    g_stmt := 'INSERT';
    if tu in ('ALL', 'FIRST') then         -- multi-table insert: object lineage only
      adv;
      loop
        if tu = 'WHEN' then
          adv;
          e := parse_expr(i, null, 'WHEN', null, 'COND');
          need('THEN');
        elsif tu = 'ELSE' then
          adv;
        elsif tu = 'INTO' then
          adv;
          spos := cur_spos;
          nm := strip_owner(read_name);
          t := add_node('TARGET', i, nm, spos, last_epos);
          add_ref(nm, 'TARGET', 'DATA');
          g_target := nvl(g_target, nm);
          alias := read_alias;
          if tt = '(' then skip_parens; end if;
          if tu = 'VALUES' then adv; skip_parens; end if;
        else
          exit;
        end if;
      end loop;
      qb := parse_query(i, null);
      g_top_qb := null;
      close_node(i);
      return;
    end if;
    need('INTO');
    spos := cur_spos;
    nm := strip_owner(read_name);
    t := add_node('TARGET', i, nm, spos, last_epos);
    g_target := nvl(g_target, nm);
    add_ref(nm, 'TARGET', 'DATA');
    alias := read_alias;
    if tt = '(' and tu(1) not in ('SELECT', 'WITH') then
      g_tcols := read_col_list;
    end if;
    if tu = 'VALUES' then
      v := add_node('VALUES', i);
      adv;
      vqb := new_qb('VALUES', null);
      if tt = '(' then
        adv;
        loop
          pos := pos + 1;
          e := parse_expr(v, vqb, 'VALUES', pos, 'SET');
          add_item(vqb, pos, 'EXPR$' || pos, expr_text(e.node), item_transform(e, null));
          exit when not take(',');
        end loop;
        need(')');
      end if;
      close_node(v);
      g_top_qb := vqb;
    else
      g_top_qb := parse_query(i, null);
    end if;
    close_node(i);
  end parse_insert;

  procedure parse_update (p_parent pls_integer) is
    u     pls_integer;
    s     pls_integer;
    si    pls_integer;
    w     pls_integer;
    uqb   pls_integer;
    sq    pls_integer;
    pos   pls_integer := 0;
    nm    varchar2(261);
    col   varchar2(261);
    alias varchar2(261);
    cols  t_names;
    e     t_einfo;
    sv    varchar2(10);
    spos  pls_integer;
  begin
    u := add_node('UPDATE', p_parent);
    adv;                                   -- UPDATE
    g_stmt := 'UPDATE';
    spos := cur_spos;
    if tt = '(' then
      skip_parens;
      note_partial('UPDATE of an inline view is not resolved');
    else
      nm := strip_owner(read_name);
      s := add_node('TARGET', u, nm, spos, last_epos);
      add_ref(nm, 'TARGET', 'DATA');
      g_target := nvl(g_target, nm);
    end if;
    alias := read_alias;
    uqb := new_qb('UPDATE', null);
    add_src(uqb, nvl(alias, nm), nm, null);
    need('SET');
    s := add_node('SET', u);
    loop
      pos := pos + 1;
      si := add_node('SET_ITEM', s);
      if tt = '(' then                     -- (c1, c2) = (SELECT ...)
        cols := read_col_list;
        need('=');
        if tt = '(' and tu(1) in ('SELECT', 'WITH') then
          sq := parse_subquery_paren(si, uqb);
          for k in 1 .. cols.count loop
            add_item(uqb, pos + k - 1, cols(k), '(' || cols(k) || ' from subquery)', 'CALCULATED');
            add_sq(uqb, pos + k - 1, sq, k);
          end loop;
          pos := pos + greatest(cols.count, 1) - 1;
        else
          e := parse_expr(si, uqb, 'SET', pos, 'SET');
        end if;
      else
        col := last_part(read_name);
        g_ast(si).node_name := col;
        need('=');
        e := parse_expr(si, uqb, 'SET', pos, 'SET');
        add_item(uqb, pos, col, expr_text(e.node), item_transform(e, col));
      end if;
      close_node(si);
      exit when not take(',');
    end loop;
    close_node(s);
    if tu = 'WHERE' then
      w := add_node('WHERE', u);
      adv;
      sv := g_ctx; g_ctx := 'FILTER';
      e := parse_expr(w, uqb, 'WHERE', null, 'COND');
      g_ctx := sv;
      close_node(w);
    end if;
    g_top_qb := uqb;
    close_node(u);
  end parse_update;

  procedure parse_delete (p_parent pls_integer) is
    d     pls_integer;
    w     pls_integer;
    t     pls_integer;
    dqb   pls_integer;
    nm    varchar2(261);
    alias varchar2(261);
    e     t_einfo;
    sv    varchar2(10);
    spos  pls_integer;
  begin
    d := add_node('DELETE', p_parent);
    adv;                                   -- DELETE
    g_stmt := 'DELETE';
    if tu = 'FROM' then adv; end if;
    spos := cur_spos;
    nm := strip_owner(read_name);
    t := add_node('TARGET', d, nm, spos, last_epos);
    add_ref(nm, 'TARGET', 'DATA');
    g_target := nvl(g_target, nm);
    alias := read_alias;
    dqb := new_qb('DELETE', null);
    add_src(dqb, nvl(alias, nm), nm, null);
    if tu = 'WHERE' then
      w := add_node('WHERE', d);
      adv;
      sv := g_ctx; g_ctx := 'FILTER';
      e := parse_expr(w, dqb, 'WHERE', null, 'COND');
      g_ctx := sv;
      close_node(w);
    end if;
    g_top_qb := null;
    close_node(d);
  end parse_delete;

  procedure parse_merge (p_parent pls_integer) is
    m     pls_integer;
    x     pls_integer;
    mqb   pls_integer;
    pos   pls_integer := 0;
    k     pls_integer;
    nm    varchar2(261);
    col   varchar2(261);
    alias varchar2(261);
    cols  t_names;
    e     t_einfo;
    sv    varchar2(10);
    spos  pls_integer;
  begin
    m := add_node('MERGE', p_parent);
    adv;                                   -- MERGE
    g_stmt := 'MERGE';
    need('INTO');
    spos := cur_spos;
    nm := strip_owner(read_name);
    x := add_node('TARGET', m, nm, spos, last_epos);
    add_ref(nm, 'TARGET', 'DATA');
    g_target := nvl(g_target, nm);
    alias := read_alias;
    mqb := new_qb('MERGE', null);
    add_src(mqb, nvl(alias, nm), nm, null);
    need('USING');
    x := add_node('USING', m);
    parse_from_item(x, mqb);
    close_node(x);
    if tu = 'ON' then
      adv;
      x := add_node('ON', m);
      e := parse_expr(x, mqb, 'ON', null, 'COND');
      close_node(x);
    end if;
    while tu = 'WHEN' loop
      adv;
      if tu = 'NOT' then adv; end if;
      need('MATCHED');
      need('THEN');
      if tu = 'UPDATE' then
        x := add_node('MERGE_UPDATE', m);
        adv;
        need('SET');
        loop
          pos := pos + 1;
          col := last_part(read_name);
          need('=');
          e := parse_expr(x, mqb, 'SET', pos, 'SET');
          add_item(mqb, pos, col, expr_text(e.node), item_transform(e, col));
          exit when not take(',');
        end loop;
        if tu = 'WHERE' then
          adv;
          sv := g_ctx; g_ctx := 'FILTER';
          e := parse_expr(x, mqb, 'WHERE', null, 'COND');
          g_ctx := sv;
        end if;
        if tu = 'DELETE' then
          adv;
          if tu = 'WHERE' then
            adv;
            sv := g_ctx; g_ctx := 'FILTER';
            e := parse_expr(x, mqb, 'WHERE', null, 'COND');
            g_ctx := sv;
          end if;
        end if;
        close_node(x);
      elsif tu = 'INSERT' then
        x := add_node('MERGE_INSERT', m);
        adv;
        cols := read_col_list;
        need('VALUES');
        need('(');
        k := 0;
        loop
          k := k + 1;
          pos := pos + 1;
          e := parse_expr(x, mqb, 'VALUES', pos, 'SET');
          add_item(mqb, pos, case when cols.exists(k) then cols(k) else 'EXPR$' || k end,
                   expr_text(e.node), item_transform(e, case when cols.exists(k) then cols(k) end));
          exit when not take(',');
        end loop;
        need(')');
        if tu = 'WHERE' then
          adv;
          sv := g_ctx; g_ctx := 'FILTER';
          e := parse_expr(x, mqb, 'WHERE', null, 'COND');
          g_ctx := sv;
        end if;
        close_node(x);
      else
        exit;
      end if;
    end loop;
    g_top_qb := mqb;
    close_node(m);
  end parse_merge;

  procedure parse_plsql (p_parent pls_integer) is
    b        pls_integer;
    c        pls_integer;
    at_start boolean := true;
    nm       varchar2(261);
    spos     pls_integer;
    guard    pls_integer;
  begin
    b := add_node('PLSQL_BLOCK', p_parent);
    loop
      guard := g_p;
      exit when tt = 'EOF';
      if tu in ('BEGIN', 'DECLARE', 'THEN', 'ELSE', 'LOOP', 'IS', 'AS') then
        adv;
        at_start := true;
      elsif tt = ';' then
        adv;
        at_start := true;
      elsif at_start and tu in ('INSERT', 'UPDATE', 'DELETE', 'MERGE') then
        case tu
          when 'INSERT' then parse_insert(b);
          when 'UPDATE' then parse_update(b);
          when 'DELETE' then parse_delete(b);
          else parse_merge(b);
        end case;
        at_start := false;
      elsif at_start and tu in ('CALL', 'EXEC', 'EXECUTE') and tt(1) = 'ID' and tu(1) != 'IMMEDIATE' then
        adv;
      elsif at_start and tt in ('ID', 'QID')
            and nvl(tu, '~') not in ('END', 'IF', 'ELSIF', 'WHILE', 'FOR', 'RETURN', 'NULL', 'COMMIT',
                                     'ROLLBACK', 'EXCEPTION', 'WHEN', 'RAISE', 'EXIT', 'OPEN', 'CLOSE',
                                     'FETCH', 'GOTO', 'PRAGMA', 'SELECT', 'EXECUTE', 'CASE', 'CONTINUE') then
        spos := cur_spos;
        nm := read_name;
        if tt in ('(', ';') then
          c := add_node('CALL', b, nm, spos, last_epos);
          add_ref(strip_owner(nm), 'CALL', 'DATA');
          if tt = '(' then skip_parens; end if;
        end if;
        at_start := false;
      else
        adv;
        at_start := false;
      end if;
      if g_p = guard then adv; end if;
    end loop;
    g_stmt := 'PLSQL';
    g_top_qb := null;
    close_node(b);
  end parse_plsql;

  procedure parse_create (p_parent pls_integer) is
    c     pls_integer;
    x     pls_integer;
    nm    varchar2(261);
    kind  varchar2(30);
    spos  pls_integer;
    expect_name boolean := true;
  begin
    c := add_node('CREATE', p_parent);
    adv;                                   -- CREATE
    if tu = 'OR' then adv; adv; end if;    -- OR REPLACE
    while tu in ('FORCE', 'NO', 'NOFORCE', 'EDITIONABLE', 'NONEDITIONABLE', 'EDITIONING',
                 'MATERIALIZED', 'GLOBAL', 'PRIVATE', 'TEMPORARY', 'SHARDED', 'DUPLICATED') loop
      if tu = 'MATERIALIZED' then kind := 'MATERIALIZED '; end if;
      adv;
    end loop;
    if tu in ('VIEW', 'TABLE') then
      kind := kind || tu;
      adv;
      spos := cur_spos;
      nm := strip_owner(read_name);
      x := add_node('TARGET', c, nm, spos, last_epos);
      g_target := nm;
      g_stmt := case when kind = 'TABLE' then 'CREATE_TABLE' else 'CREATE_VIEW' end;
      add_ref(nm, 'TARGET', 'DATA');
      if tt = '(' then                     -- view column list (may include constraints)
        adv;
        loop
          exit when tt in (')', 'EOF');
          if expect_name and tt in ('ID', 'QID') then
            g_tcols(g_tcols.count + 1) := substr(tk().utxt, 1, 128);
            expect_name := false;
          elsif tt = ',' then
            expect_name := true;
          end if;
          if tt = '(' then skip_parens; else adv; end if;
        end loop;
        need(')');
        if kind = 'TABLE' then g_tcols.delete; end if;
      end if;
      loop                                 -- skip physical / refresh clauses up to AS
        exit when tu = 'AS' or tt = 'EOF';
        if tt = '(' then skip_parens; else adv; end if;
      end loop;
      if take('AS') then
        g_top_qb := parse_query(c, null);
      end if;
    else
      g_stmt := 'UNKNOWN';
      note_partial('Unsupported CREATE statement');
      skip_clause;
    end if;
    close_node(c);
  end parse_create;

  procedure parse_statement is
    root pls_integer;
    x    pls_integer;
    nm   varchar2(261);
    spos pls_integer;
  begin
    root := add_node('STATEMENT', null, null, 1);
    if tu = 'CREATE' then
      parse_create(root);
    elsif tu in ('SELECT', 'WITH') or tt = '(' then
      g_stmt := 'SELECT';
      g_top_qb := parse_query(root, null);
    elsif tu = 'INSERT' then
      parse_insert(root);
    elsif tu = 'UPDATE' then
      parse_update(root);
    elsif tu = 'DELETE' then
      parse_delete(root);
    elsif tu = 'MERGE' then
      parse_merge(root);
    elsif tu in ('BEGIN', 'DECLARE', 'CALL', 'EXEC', 'EXECUTE') then
      parse_plsql(root);
    elsif tu = 'TRUNCATE' then
      adv;
      if tu = 'TABLE' then adv; end if;
      g_stmt := 'TRUNCATE';
      spos := cur_spos;
      nm := strip_owner(read_name);
      x := add_node('TARGET', root, nm, spos, last_epos);
      add_ref(nm, 'TARGET', 'DATA');
      g_target := nm;
    else
      g_stmt := 'UNKNOWN';
      note_partial('Unsupported statement starting with ' || substr(tk().txt, 1, 30));
    end if;
    while tt = ';' or tu = '/' loop adv; end loop;
    if tu = 'WITH' and tu(1) in ('READ', 'CHECK') then
      while tt not in ('EOF', ';') loop adv; end loop;
      while tt = ';' loop adv; end loop;
    end if;
    if tt != 'EOF' then
      note_partial('Unparsed text from char ' || cur_spos || ': ' || substr(tk().txt, 1, 30));
    end if;
    g_p := g_ntok + 1;
    close_node(root);
  end parse_statement;

  ------------------------------------------------------------------------------
  -- Dictionary access (cached)
  ------------------------------------------------------------------------------
  function dict_cols (p_obj varchar2) return t_names is
    l   t_names;
    own varchar2(128);
    nm  varchar2(261);
  begin
    if not g_use_dict or p_obj is null or instr(p_obj, '@') > 0 then return l; end if;
    if g_dict.exists(p_obj) then return g_dict(p_obj); end if;
    if instr(p_obj, '.') > 0 then
      own := substr(p_obj, 1, instr(p_obj, '.') - 1);
      nm  := substr(p_obj, instr(p_obj, '.') + 1);
    else
      own := g_owner;
      nm  := p_obj;
    end if;
    begin
      select column_name bulk collect into l
      from   all_tab_columns
      where  owner = own and table_name = nm
      order  by column_id;
      if l.count = 0 then
        select c.column_name bulk collect into l
        from   all_synonyms s
        join   all_tab_columns c on c.owner = s.table_owner and c.table_name = s.table_name
        where  s.owner = own and s.synonym_name = nm and s.db_link is null
        order  by c.column_id;
      end if;
      if l.count = 0 then
        select c.column_name bulk collect into l
        from   all_synonyms s
        join   all_tab_columns c on c.owner = s.table_owner and c.table_name = s.table_name
        where  s.owner = 'PUBLIC' and s.synonym_name = nm and s.db_link is null
        order  by c.column_id;
      end if;
    exception
      when others then l.delete;
    end;
    g_dict(p_obj) := l;
    return l;
  end dict_cols;

  function names_has (p_names t_names, p_col varchar2) return boolean is
  begin
    for i in 1 .. p_names.count loop
      if p_names(i) = p_col then return true; end if;
    end loop;
    return false;
  end names_has;

  ------------------------------------------------------------------------------
  -- Column lineage resolution
  ------------------------------------------------------------------------------
  function rank_of (p_tr varchar2) return pls_integer is
  begin
    return case p_tr
             when 'DIRECT'     then 1
             when 'RENAME'     then 2
             when 'CALCULATED' then 3
             when 'CASE'       then 4
             when 'AGGREGATE'  then 5
             when 'WINDOW'     then 6
             else 0
           end;
  end rank_of;

  function combine (a varchar2, b varchar2) return varchar2 is
  begin
    if rank_of(b) > rank_of(a) then return b; end if;
    return nvl(a, b);
  end combine;

  function combine_role (p_outer varchar2, p_inner varchar2) return varchar2 is
  begin
    return case when nvl(p_outer, 'VALUE') = 'VALUE' then nvl(p_inner, 'VALUE') else p_outer end;
  end combine_role;

  procedure add_lin (p_list in out nocopy t_lins, p_obj varchar2, p_col varchar2,
                     p_tr varchar2, p_role varchar2, p_res varchar2) is
    k pls_integer := p_list.count + 1;
  begin
    p_list(k).obj        := p_obj;
    p_list(k).col        := p_col;
    p_list(k).transform  := p_tr;
    p_list(k).role       := p_role;
    p_list(k).resolution := p_res;
  end add_lin;

  function out_find (p_qb pls_integer, p_col varchar2) return pls_integer is
  begin
    compute_outputs(p_qb);
    if g_qb(p_qb).out_first is null then return null; end if;   -- still being computed
    for i in g_qb(p_qb).out_first .. g_qb(p_qb).out_first + g_qb(p_qb).out_cnt - 1 loop
      if g_outs(i).name = p_col then return i; end if;
    end loop;
    return null;
  end out_find;

  function src_has_col (p_src pls_integer, p_col varchar2) return boolean is
  begin
    if g_src(p_src).dq is not null then
      return out_find(g_src(p_src).dq, p_col) is not null;
    elsif g_src(p_src).obj is not null then
      return names_has(dict_cols(g_src(p_src).obj), p_col);
    end if;
    return false;
  end src_has_col;

  function find_source (p_qb pls_integer, p_qual varchar2) return pls_integer is
    q pls_integer := p_qb;
  begin
    while q is not null loop
      for i in 1 .. g_src.count loop
        if g_src(i).qb = q then
          if g_src(i).alias = p_qual then return i; end if;
          if g_src(i).alias is null and g_src(i).obj is not null
             and (g_src(i).obj = p_qual or last_part(g_src(i).obj) = p_qual) then
            return i;
          end if;
        end if;
      end loop;
      q := g_qb(q).outer_qb;
    end loop;
    return null;
  end find_source;

  -- true when the columns of a FROM source cannot be known (no dictionary
  -- access, table function, derived table with an unexpanded SELECT *)
  function src_cols_unknown (p_src pls_integer) return boolean is
    dq pls_integer := g_src(p_src).dq;
  begin
    if dq is not null then
      compute_outputs(dq);
      if g_qb(dq).out_first is null then return true; end if;
      for i in g_qb(dq).out_first .. g_qb(dq).out_first + g_qb(dq).out_cnt - 1 loop
        if g_outs(i).name = '*' then return true; end if;
      end loop;
      return false;
    elsif g_src(p_src).obj is not null then
      return dict_cols(g_src(p_src).obj).count = 0;
    end if;
    return true;
  end src_cols_unknown;

  function resolve (p_qb pls_integer, p_qual varchar2, p_col varchar2) return t_lins is
    l        t_lins;
    s        pls_integer;
    q        pls_integer := p_qb;
    o        pls_integer;
    cands    t_ints;
    matches  pls_integer;
    unknowns pls_integer;
    s_match  pls_integer;
    s_unk    pls_integer;
    fallback pls_integer;
    l_res    varchar2(30) := 'RESOLVED';
    dq       pls_integer;
  begin
    if p_qual is not null then
      s := find_source(p_qb, strip_owner(p_qual));
      if s is null then
        add_lin(l, p_qual, p_col, 'DIRECT', 'VALUE', 'UNRESOLVED');
        return l;
      end if;
    else
      -- unqualified column: innermost query block first, then enclosing
      -- blocks (correlated subqueries)
      while q is not null and s is null loop
        cands.delete;
        for i in 1 .. g_src.count loop
          if g_src(i).qb = q then cands(cands.count + 1) := i; end if;
        end loop;
        if cands.count > 0 then
          matches := 0; unknowns := 0; s_match := null; s_unk := null;
          for k in 1 .. cands.count loop
            if src_has_col(cands(k), p_col) then
              matches := matches + 1;
              s_match := cands(k);
            elsif src_cols_unknown(cands(k)) then
              unknowns := unknowns + 1;
              s_unk := cands(k);
            end if;
          end loop;
          if matches = 1 then
            s := s_match;
          elsif matches > 1 then
            add_lin(l, null, p_col, 'DIRECT', 'VALUE', 'AMBIGUOUS');
            return l;
          elsif cands.count = 1 then
            -- single source: it owns the column unless an outer block does
            fallback := nvl(fallback, cands(1));
            if unknowns = 1 then s := cands(1); end if;
          elsif unknowns = 1 then
            s := s_unk;                    -- the only source whose columns are unknown
            l_res := 'INFERRED';
          elsif unknowns > 1 then
            add_lin(l, null, p_col, 'DIRECT', 'VALUE', 'AMBIGUOUS');
            return l;
          end if;
          -- matches = 0 and unknowns = 0: the column belongs to an outer block
        end if;
        q := g_qb(q).outer_qb;
      end loop;
      if s is null then
        s := fallback;
        l_res := 'INFERRED';
      end if;
      if s is null then
        add_lin(l, null, p_col, 'DIRECT', 'VALUE', 'UNRESOLVED');
        return l;
      end if;
    end if;

    dq := g_src(s).dq;
    if dq is not null and g_qb(dq).visiting then
      return l;                            -- recursive CTE reading itself: nothing new upstream
    end if;
    if dq is not null then
      o := out_find(dq, p_col);
      if o is not null then
        if g_outs(o).lins.count = 0 then
          add_lin(l, null, null, nvl(g_outs(o).transform, 'CONSTANT'), 'VALUE', 'CONSTANT');
        else
          l := g_outs(o).lins;
        end if;
      else
        -- pass through an unexpanded SELECT * of the derived table
        for i in nvl(g_qb(dq).out_first, 1) .. nvl(g_qb(dq).out_first + g_qb(dq).out_cnt - 1, 0) loop
          if g_outs(i).name = '*' then
            for k in 1 .. g_outs(i).lins.count loop
              add_lin(l, g_outs(i).lins(k).obj, p_col, 'DIRECT', g_outs(i).lins(k).role, 'VIA_STAR');
            end loop;
          end if;
        end loop;
        if l.count = 0 then
          add_lin(l, null, p_col, 'DIRECT', 'VALUE', 'UNRESOLVED');
        end if;
      end if;
    elsif g_src(s).obj is not null then
      add_lin(l, g_src(s).obj, p_col, 'DIRECT', 'VALUE', l_res);
    else
      add_lin(l, null, p_col, 'DIRECT', 'VALUE', 'UNRESOLVED');
    end if;
    return l;
  end resolve;

  procedure expand_star (p_qb pls_integer, p_qual varchar2, p_outs in out nocopy t_outs) is
    n pls_integer;
    d t_names;
  begin
    for s in 1 .. g_src.count loop
      if g_src(s).qb = p_qb
         and (p_qual is null
              or g_src(s).alias = p_qual
              or (g_src(s).alias is null and (g_src(s).obj = p_qual or last_part(g_src(s).obj) = p_qual))) then
        if g_src(s).dq is not null then
          compute_outputs(g_src(s).dq);
          for i in nvl(g_qb(g_src(s).dq).out_first, 1)
                .. nvl(g_qb(g_src(s).dq).out_first + g_qb(g_src(s).dq).out_cnt - 1, 0) loop
            n := p_outs.count + 1;
            p_outs(n) := g_outs(i);
          end loop;
        elsif g_src(s).obj is not null then
          d := dict_cols(g_src(s).obj);
          if d.count > 0 then
            for k in 1 .. d.count loop
              n := p_outs.count + 1;
              p_outs(n).name := d(k);
              p_outs(n).expr := nvl(g_src(s).alias, g_src(s).obj) || '.' || d(k);
              p_outs(n).transform := 'DIRECT';
              add_lin(p_outs(n).lins, g_src(s).obj, d(k), 'DIRECT', 'VALUE', 'DICTIONARY');
            end loop;
          else
            n := p_outs.count + 1;
            p_outs(n).name := '*';
            p_outs(n).expr := nvl(g_src(s).alias, g_src(s).obj) || '.*';
            p_outs(n).transform := 'STAR';
            add_lin(p_outs(n).lins, g_src(s).obj, '*', 'STAR', 'VALUE', 'UNEXPANDED');
          end if;
        end if;
      end if;
    end loop;
  end expand_star;

  procedure compute_outputs (p_qb pls_integer) is
    l_outs t_outs;
    n      pls_integer;
    o      pls_integer;
    sub    t_lins;
    br     pls_integer;
    first  boolean := true;
    bo     pls_integer;
  begin
    if p_qb is null or not g_qb.exists(p_qb) then return; end if;
    if g_qb(p_qb).out_done or g_qb(p_qb).visiting then return; end if;
    g_qb(p_qb).visiting := true;

    if g_qb(p_qb).kind = 'SETOP' then
      for b in 1 .. g_br.count loop
        if g_br(b).setop = p_qb then
          br := g_br(b).br;
          compute_outputs(br);
          if g_qb(br).out_first is null then continue; end if;
          if first then
            for k in 1 .. g_qb(br).out_cnt loop
              l_outs(k) := g_outs(g_qb(br).out_first + k - 1);
            end loop;
            first := false;
          else
            for k in 1 .. least(l_outs.count, g_qb(br).out_cnt) loop
              bo := g_qb(br).out_first + k - 1;
              l_outs(k).transform := combine(l_outs(k).transform, g_outs(bo).transform);
              for j in 1 .. g_outs(bo).lins.count loop
                l_outs(k).lins(l_outs(k).lins.count + 1) := g_outs(bo).lins(j);
              end loop;
            end loop;
          end if;
        end if;
      end loop;
    else
      for i in 1 .. g_item.count loop
        if g_item(i).qb = p_qb then
          if g_item(i).is_star then
            expand_star(p_qb, g_item(i).star_qual, l_outs);
          else
            n := l_outs.count + 1;
            l_outs(n).name      := g_item(i).name;
            l_outs(n).expr      := g_item(i).expr;
            l_outs(n).transform := g_item(i).transform;
            for r in 1 .. g_cref.count loop
              if g_cref(r).qb = p_qb and g_cref(r).item_pos = g_item(i).pos then
                sub := resolve(p_qb, g_cref(r).qual, g_cref(r).col);
                for k in 1 .. sub.count loop
                  add_lin(l_outs(n).lins, sub(k).obj, sub(k).col,
                          combine(g_item(i).transform, sub(k).transform),
                          combine_role(g_cref(r).role, sub(k).role), sub(k).resolution);
                end loop;
              end if;
            end loop;
            for q in 1 .. g_sq.count loop
              if g_sq(q).qb = p_qb and g_sq(q).item_pos = g_item(i).pos then
                compute_outputs(g_sq(q).sq);
                if g_qb(g_sq(q).sq).out_first is not null
                   and g_qb(g_sq(q).sq).out_cnt >= nvl(g_sq(q).sq_pos, 1) then
                  o := g_qb(g_sq(q).sq).out_first + nvl(g_sq(q).sq_pos, 1) - 1;
                  for k in 1 .. g_outs(o).lins.count loop
                    add_lin(l_outs(n).lins, g_outs(o).lins(k).obj, g_outs(o).lins(k).col,
                            combine(g_item(i).transform, g_outs(o).lins(k).transform),
                            g_outs(o).lins(k).role, g_outs(o).lins(k).resolution);
                  end loop;
                end if;
              end if;
            end loop;
            if g_item(i).agg_no_ref and l_outs(n).lins.count = 0 then   -- COUNT(*)
              for s in 1 .. g_src.count loop
                if g_src(s).qb = p_qb and g_src(s).obj is not null then
                  add_lin(l_outs(n).lins, g_src(s).obj, '*', g_item(i).transform, 'VALUE', 'RESOLVED');
                end if;
              end loop;
            end if;
          end if;
        end if;
      end loop;
    end if;

    if g_qb_names.exists(p_qb) then
      for k in 1 .. least(l_outs.count, g_qb_names(p_qb).count) loop
        l_outs(k).name := g_qb_names(p_qb)(k);
      end loop;
    end if;

    g_qb(p_qb).out_first := g_outs.count + 1;
    for k in 1 .. l_outs.count loop
      g_outs(g_outs.count + 1) := l_outs(k);
    end loop;
    g_qb(p_qb).out_cnt  := l_outs.count;
    g_qb(p_qb).out_done := true;
    g_qb(p_qb).visiting := false;
  end compute_outputs;

  procedure build_result is
    type t_seen is table of boolean index by varchar2(1000);
    seen     t_seen;
    names    t_names;
    d        t_names;
    tgt      varchar2(261) := nvl(g_target, g_hint);
    qb       pls_integer := g_top_qb;
    cnt      pls_integer;
    first    pls_integer;
    has_star boolean := false;
    nm       varchar2(128);
    k        pls_integer;
    key      varchar2(1000);

    procedure emit (p_col varchar2, p_pos pls_integer, p_expr varchar2, p_tr varchar2,
                    p_obj varchar2, p_scol varchar2, p_role varchar2, p_res varchar2) is
      r pls_integer;
    begin
      key := p_pos || '|' || p_obj || '|' || p_scol || '|' || p_role;
      if seen.exists(key) then return; end if;
      seen(key) := true;
      r := g_result.count + 1;
      g_result(r).target_column  := p_col;
      g_result(r).column_pos     := p_pos;
      g_result(r).expression     := p_expr;
      g_result(r).transform_type := p_tr;
      g_result(r).source_object  := p_obj;
      g_result(r).source_column  := p_scol;
      g_result(r).ref_role       := p_role;
      g_result(r).resolution     := p_res;
    end emit;
  begin
    g_result.delete;
    g_res_target := tgt;
    if qb is null or tgt is null or g_stmt in ('DELETE', 'PLSQL', 'TRUNCATE') then return; end if;
    compute_outputs(qb);
    cnt   := g_qb(qb).out_cnt;
    first := g_qb(qb).out_first;
    for i in 1 .. cnt loop
      if g_outs(first + i - 1).name = '*' then has_star := true; end if;
    end loop;
    if g_qb(qb).kind in ('SELECT', 'SETOP', 'VALUES') then
      if g_tcols.count > 0 then
        names := g_tcols;
      elsif not has_star then
        d := dict_cols(tgt);
        if d.count = cnt then names := d; end if;
      end if;
    end if;
    for i in 1 .. cnt loop
      k  := first + i - 1;
      nm := case when names.exists(i) and not has_star then names(i) else g_outs(k).name end;
      if g_outs(k).lins.count = 0 then
        emit(nm, i, g_outs(k).expr,
             case when g_outs(k).transform in ('AGGREGATE', 'WINDOW') then g_outs(k).transform else 'CONSTANT' end,
             null, null, 'VALUE', 'CONSTANT');
      else
        for j in 1 .. g_outs(k).lins.count loop
          emit(nm, i, g_outs(k).expr, g_outs(k).lins(j).transform, g_outs(k).lins(j).obj,
               g_outs(k).lins(j).col, g_outs(k).lins(j).role, g_outs(k).lins(j).resolution);
        end loop;
      end if;
    end loop;
  end build_result;

  ------------------------------------------------------------------------------
  -- Public API
  ------------------------------------------------------------------------------
  procedure reset_state is
  begin
    g_tok.delete;   g_ntok := 0; g_p := 1;
    g_ast.delete;   g_kids.delete;
    g_refs.delete;  g_qb.delete;  g_src.delete;  g_item.delete;
    g_cref.delete;  g_sq.delete;  g_cte.delete;  g_br.delete;
    g_outs.delete;  g_qb_names.delete; g_tcols.delete; g_result.delete;
    g_top_qb := null; g_target := null; g_res_target := null; g_stmt := null;
    g_status := 'OK'; g_msg := null; g_ctx := 'DATA'; g_role := 'VALUE';
    g_buf := null; g_buf_start := null; g_buf_len := 0;
  end reset_state;

  function parse (
    p_sql          in clob,
    p_target_hint  in varchar2 default null,
    p_owner        in varchar2 default null,
    p_use_dict     in boolean  default true
  ) return varchar2 is
  begin
    reset_state;
    g_sql      := p_sql;
    g_len      := nvl(dbms_lob.getlength(p_sql), 0);
    g_owner    := upper(nvl(p_owner, sys_context('USERENV', 'CURRENT_SCHEMA')));
    g_use_dict := nvl(p_use_dict, true);
    g_hint     := norm_name(p_target_hint);
    if g_len = 0 then
      g_status := 'FAILED';
      g_msg := 'Empty SQL text';
      return g_status;
    end if;
    begin
      tokenize_all;
      g_p := 1;
      parse_statement;
    exception
      when others then
        g_status := case when g_refs.count > 0 then 'PARTIAL' else 'FAILED' end;
        g_msg := substrb('Parse error near char ' || cur_spos || ': ' || sqlerrm || ' '
                         || dbms_utility.format_error_backtrace, 1, 4000);
    end;
    begin
      build_result;
    exception
      when others then
        note_partial('Column lineage error: ' || sqlerrm);
    end;
    if g_refs.count = 0 and g_stmt in ('UNKNOWN') then
      g_status := 'FAILED';
    end if;
    return g_status;
  end parse;

  function status        return varchar2    is begin return g_status; end;
  function message       return varchar2    is begin return g_msg; end;
  function stmt_type     return varchar2    is begin return g_stmt; end;
  function target_object return varchar2    is begin return g_target; end;
  function token_count   return pls_integer is begin return g_ntok; end;
  function obj_refs      return t_obj_refs  is begin return g_refs; end;
  function col_lineage   return t_col_lins  is begin return g_result; end;

  function ast return t_ast_tab is
    l t_ast_tab := t_ast_tab();
  begin
    l.extend(g_ast.count);
    for i in 1 .. g_ast.count loop
      l(i) := g_ast(i);
      if l(i).node_type not in ('STATEMENT') or g_len <= 4000 then
        l(i).node_text := src_text(l(i).start_pos, l(i).end_pos);
      end if;
    end loop;
    return l;
  end ast;

  procedure clear_cache is
  begin
    g_dict.delete;
  end clear_cache;

  function save (
    p_run_id         in number,
    p_source_kind    in varchar2,
    p_job_num        in number   default null,
    p_object_name    in varchar2 default null,
    p_lineage_origin in varchar2 default null,
    p_save_ast       in boolean  default true
  ) return number is
    pid  number;
    a    t_ast_tab;
    tgt  varchar2(261) := nvl(g_res_target, nvl(g_target, p_object_name));
    nast pls_integer := g_ast.count;
  begin
    pid := lin_parse_seq.nextval;
    insert into lin_parse (parse_id, run_id, source_kind, job_num, object_name, stmt_type,
                           status, message, token_count, ast_node_count, sql_text)
    values (pid, p_run_id, p_source_kind, p_job_num, nvl(p_object_name, g_target), g_stmt,
            g_status, g_msg, g_ntok, nast, g_sql);

    if p_save_ast and g_ast.count > 0 then
      a := ast;
      forall i in 1 .. a.count
        insert into lin_ast_node (parse_id, node_id, parent_id, node_type, node_name, node_text,
                                  start_pos, end_pos, depth, sibling_seq)
        values (pid, a(i).node_id, a(i).parent_id, a(i).node_type, a(i).node_name, a(i).node_text,
                a(i).start_pos, a(i).end_pos, a(i).depth, a(i).sibling_seq);
    end if;

    if p_lineage_origin is not null and g_result.count > 0 and tgt is not null then
      forall i in 1 .. g_result.count
        insert into lin_column_lineage (run_id, parse_id, lineage_origin, job_num, target_object,
                                        target_column, column_pos, expression, transform_type,
                                        source_object, source_column, ref_role, resolution)
        values (p_run_id, pid, p_lineage_origin, p_job_num, tgt,
                g_result(i).target_column, g_result(i).column_pos, g_result(i).expression,
                g_result(i).transform_type, g_result(i).source_object, g_result(i).source_column,
                g_result(i).ref_role, g_result(i).resolution);
    end if;
    return pid;
  end save;

  function parse_tree (p_sql in clob, p_owner in varchar2 default null) return t_ast_tab pipelined is
    st varchar2(20);
    a  t_ast_tab;
  begin
    st := parse(p_sql, null, p_owner, true);
    a := ast;
    for i in 1 .. a.count loop
      pipe row (a(i));
    end loop;
    return;
  end parse_tree;

  function tokens (p_sql in clob) return t_token_tab pipelined is
    r t_token_row;
  begin
    reset_state;
    g_sql := p_sql;
    g_len := nvl(dbms_lob.getlength(p_sql), 0);
    tokenize_all;
    for i in 1 .. g_ntok loop
      r.token_no   := i;
      r.token_type := g_tok(i).ttype;
      r.token_text := substrb(g_tok(i).txt, 1, 4000);
      r.start_pos  := g_tok(i).spos;
      r.end_pos    := g_tok(i).epos;
      pipe row (r);
    end loop;
    return;
  end tokens;

  ------------------------------------------------------------------------------
  -- Keyword tables
  ------------------------------------------------------------------------------
  procedure load_set (p_set in out nocopy t_set, p_words varchar2) is
    w varchar2(128);
    i pls_integer := 1;
  begin
    loop
      w := regexp_substr(p_words, '[^ ]+', 1, i);
      exit when w is null;
      p_set(w) := true;
      i := i + 1;
    end loop;
  end load_set;

begin
  load_set(s_stop,
    'SELECT FROM WHERE GROUP HAVING ORDER UNION INTERSECT MINUS EXCEPT CONNECT START INTO VALUES '
 || 'SET ON USING JOIN INNER LEFT RIGHT FULL CROSS NATURAL OUTER WHEN THEN ELSE END FETCH OFFSET '
 || 'RETURNING LOG MODEL PIVOT UNPIVOT WINDOW FOR AS WITH');
  load_set(s_oper,
    'AND OR NOT IS IN LIKE LIKE2 LIKE4 LIKEC BETWEEN ESCAPE EXISTS PRIOR ANY SOME ALL DISTINCT '
 || 'UNIQUE MEMBER OF SUBMULTISET MULTISET COLLATE');
  load_set(s_noise, 'BY LEADING TRAILING BOTH SETS');
  load_set(s_order, 'ASC DESC NULLS FIRST LAST');
  load_set(s_win,
    'PARTITION BY ORDER ROWS RANGE GROUPS BETWEEN UNBOUNDED PRECEDING FOLLOWING CURRENT ROW '
 || 'EXCLUDE TIES OTHERS NO DENSE_RANK SIBLINGS KEEP');
  load_set(s_pseudo,
    'NULL TRUE FALSE SYSDATE SYSTIMESTAMP CURRENT_DATE CURRENT_TIMESTAMP LOCALTIMESTAMP ROWNUM '
 || 'LEVEL USER UID ROWID DBTIMEZONE SESSIONTIMEZONE ORA_ROWSCN CONNECT_BY_ISLEAF CONNECT_BY_ISCYCLE');
  load_set(s_agg,
    'SUM COUNT MIN MAX AVG LISTAGG MEDIAN STDDEV STDDEV_POP STDDEV_SAMP VARIANCE VAR_POP VAR_SAMP '
 || 'COLLECT XMLAGG JSON_ARRAYAGG JSON_OBJECTAGG CORR COVAR_POP COVAR_SAMP PERCENTILE_CONT '
 || 'PERCENTILE_DISC APPROX_COUNT_DISTINCT APPROX_SUM APPROX_MEDIAN ANY_VALUE REGR_SLOPE '
 || 'REGR_INTERCEPT STATS_MODE BIT_AND_AGG BIT_OR_AGG BIT_XOR_AGG');
end lin_sql_parser;
/
