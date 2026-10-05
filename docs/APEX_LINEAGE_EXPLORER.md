# APEX Lineage Explorer — step by step

A one-page APEX application where you pick an object and a column and see:

1. **How the column is calculated**: expression, transformation type, source columns.
2. **The full lineage chain** upstream (back to the source tables) or downstream (impact).
3. **A lineage tree** you can expand node by node.
4. **The object-level lineage**: jobs and views feeding the object.
5. **The SQL of the view** that defines the column.

Tested queries; works on Oracle 19c with APEX 19.x or later.

---

## Step 0: Prerequisites (SQL Developer)

1. The lineage engine is installed and a run has completed:
   ```sql
   select run_id, status from lin_run order by run_id desc fetch first 1 rows only;   -- COMPLETED
   ```
2. Install the APEX helper views (in the schema that owns the `LIN_*` tables):
   ```sql
   @C:\lineage\sql\07_apex_support.sql
   ```
   This creates:
   * `LIN_V_APEX_OBJECT_LOV`: objects for the object picker
   * `LIN_V_APEX_COLUMN_LOV`: columns per object for the column picker
   * `LIN_V_APEX_COLUMN_CALC`: one row per column: expression, transform type, sources

## Step 1: Give APEX access to the lineage schema

The application's **parsing schema** must be the schema that owns the `LIN_*` tables
(e.g. `PCOE_COE_BOOKINGS`). The packages run with invoker rights and read the
`LIN_*` tables of the schema APEX parses as.

* If your workspace already uses that schema, skip this step.
* Otherwise, an APEX instance administrator assigns it:
  **APEX Administration Services → Manage Workspaces → Manage Workspace to Schema Assignments → Add**
  (workspace = yours, schema = the lineage schema).

## Step 2: Create the application

1. **App Builder → Create → New Application**.
2. Name: `Lineage Explorer`. Appearance: any.
3. **Advanced Settings → Schema**: the lineage schema from Step 1.
4. Keep the default **Home** page (a blank page) → **Create Application**.

## Step 3: Page items (the selectors)

Open **Page 1 (Home)** in Page Designer. Create a **Static Content** region `Select column`
(Template: *Standard*), then add these items to it:

| Item | Type | Settings |
|---|---|---|
| `P1_OBJECT` | Popup LOV | **List of Values → SQL Query**:<br>`select display_value || '  (' || node_type || ', ' || node_class || ')' d, return_value r from lin_v_apex_object_lov order by 1`<br>Display Extra Values: No |
| `P1_COLUMN` | Select List | **SQL Query**:<br>`select column_name d, column_name r from lin_v_apex_column_lov where object_name = :P1_OBJECT order by column_pos nulls last, column_name`<br>**Cascading List of Values → Parent Item(s)**: `P1_OBJECT` |
| `P1_DIRECTION` | Radio Group | **Static Values**: `STATIC:Upstream (how it is calculated);UPSTREAM,Downstream (where it goes);DOWNSTREAM`<br>Default: `UPSTREAM`. Number of columns: 2 |
| `SHOW` | Button | Label `Show lineage`, Action: **Submit Page** |

> Tip: instead of the button you can add a **Dynamic Action** on `P1_COLUMN` / `P1_DIRECTION`
> *Change* → *Refresh* each report region below (every region already has
> *Page Items to Submit* set, see below).

## Step 4: Region "How it is calculated"

Create region **Classic Report** `How it is calculated`:

```sql
select c.target_column    as "Column",
       c.transform_type   as "Transformation",
       c.expression       as "Expression",
       c.value_sources    as "Calculated from",
       c.condition_sources as "Conditions / partitions",
       c.job_nums         as "Loaded by job",
       c.has_unresolved   as "Unresolved refs"
from   lin_v_apex_column_calc c
where  c.target_object = :P1_OBJECT
and    c.target_column = :P1_COLUMN
```

* **Page Items to Submit**: `P1_OBJECT,P1_COLUMN`
* **Server-side Condition**: *Item is NOT NULL* → `P1_COLUMN`

## Step 5: Region "Lineage chain" (every hop with its expression)

Create region **Interactive Report** `Lineage chain`:

```sql
select lvl              as "Level",
       target_object    as "Target object",
       target_column    as "Target column",
       transform_type   as "Transformation",
       expression       as "Expression",
       source_object    as "Source object",
       source_column    as "Source column",
       ref_role         as "Role",
       lineage_origin   as "Defined in",
       job_num          as "Job",
       path             as "Path"
from   table(lin_engine.trace_column(:P1_OBJECT, :P1_COLUMN, nvl(:P1_DIRECTION, 'UPSTREAM')))
```

* **Page Items to Submit**: `P1_OBJECT,P1_COLUMN,P1_DIRECTION`
* **Server-side Condition**: *Item is NOT NULL* → `P1_COLUMN`
* Optional: in the report's *Actions → Format → Highlight* add a rule
  `Transformation in ('AGGREGATE','WINDOW','CASE','CALCULATED')` so calculations stand out.
* Users can download the chain as CSV/Excel via *Actions → Download*.

## Step 6: Region "Lineage tree" (expandable)

Create region **Tree** `Lineage tree` with this SQL:

```sql
with t as (
  select distinct path, lvl, source_object, source_column, target_object, target_column,
         transform_type, expression, job_num
  from   table(lin_engine.trace_column(:P1_OBJECT, :P1_COLUMN, nvl(:P1_DIRECTION, 'UPSTREAM')))
), nodes as (
  select upper(:P1_OBJECT) || '.' || upper(:P1_COLUMN) id,
         cast(null as varchar2(4000))                    parent_id,
         upper(:P1_OBJECT) || '.' || upper(:P1_COLUMN) label,
         'Selected column'                               tooltip,
         'fa fa-columns'                                 icon
  from   dual
  union all
  select path,
         substr(path, 1, instr(path, case when upper(:P1_DIRECTION) like 'DOWN%' then ' -> ' else ' <- ' end, -1) - 1),
         case when upper(:P1_DIRECTION) like 'DOWN%' then target_object || '.' || target_column
              else nvl2(source_object, source_object || '.' || source_column, '(constant)') end
           || '  [' || transform_type || nvl2(job_num, ', job ' || job_num, '') || ']',
         expression,
         case when transform_type in ('AGGREGATE', 'WINDOW') then 'fa fa-sigma'
              when transform_type in ('CALCULATED', 'CASE')  then 'fa fa-calculator'
              else 'fa fa-arrow-left' end
  from  (select t.*, row_number() over (partition by path order by job_num nulls first) rn from t)
  where  rn = 1
)
select id, parent_id, label, tooltip, icon from nodes
```

Tree **Attributes**:

| Attribute | Value |
|---|---|
| Node Label Column | `LABEL` |
| Node Value Column | `ID` |
| Hierarchy | *Computed without Start With* (roots = rows whose `PARENT_ID` is null); **Parent Key Column** `PARENT_ID`. Attribute labels differ slightly between APEX versions: what matters is key = `ID`, parent = `PARENT_ID`. |
| Tooltip | *Database Column* → `TOOLTIP` (the expression) |
| Icon CSS Class Column | `ICON` |
| Default Expand | Expand all |

* **Page Items to Submit**: `P1_OBJECT,P1_COLUMN,P1_DIRECTION`
* **Server-side Condition**: *Item is NOT NULL* → `P1_COLUMN`

Hover a node to see the expression that produced it.

## Step 7: Region "Object lineage" (jobs and views)

Create region **Interactive Report** `Object lineage`:

```sql
select lvl          as "Level",
       source_node  as "Source",
       target_node  as "Target",
       job_num      as "Job",
       job_names    as "Job groups",
       action_type  as "Action",
       edge_origin  as "Edge from",
       ref_context  as "Data / Filter",
       path         as "Path"
from   table(lin_engine.trace_object(:P1_OBJECT, nvl(:P1_DIRECTION, 'UPSTREAM')))
```

* **Page Items to Submit**: `P1_OBJECT,P1_DIRECTION`
* **Server-side Condition**: *Item is NOT NULL* → `P1_OBJECT`

## Step 8: Region "View SQL"

Create region **PL/SQL Dynamic Content** `View SQL`:

```sql
declare
  l_text clob;
  l_pos  pls_integer := 1;
begin
  select max(view_text) into l_text
  from   lin_view_ddl
  where  run_id = (select run_id from lin_v_latest_run)
  and    view_name = :P1_OBJECT;

  if l_text is null then
    htp.p('<p>' || apex_escape.html(:P1_OBJECT) || ' is not a view (or its text was not captured).</p>');
    return;
  end if;
  htp.p('<pre style="white-space:pre-wrap;max-height:500px;overflow:auto">');
  while l_pos <= dbms_lob.getlength(l_text) loop
    htp.prn(apex_escape.html(dbms_lob.substr(l_text, 4000, l_pos)));
    l_pos := l_pos + 4000;
  end loop;
  htp.p('</pre>');
end;
```

* **Page Items to Submit**: `P1_OBJECT` (APEX 20.2+; on older versions the page submit is enough)
* **Server-side Condition**: *Item is NOT NULL* → `P1_OBJECT`

(Oracle 21+/APEX 21+ users can use a **Code Editor** item instead.)

## Step 9: Run it

1. Click **Run** (top right).
2. Pick an object, e.g. `APP_SNAP_BKG_YTD_STERM_V`, then a column, e.g. `CCV_AMOUNT_LOCAL`.
3. Click **Show lineage**. You get:
   * the formula: `sum(nvl(case when sbc.mrr_type_dtl = 'STerm' then sbc.deal_length * sbc.mrr_loc …) over (partition by sbc.account_id)`, type `WINDOW`
   * the chain down to `SNAP_BKG_COMPARE.CURR_MRR_LOC` / `PREV_MRR_LOC`, `HDR_START_DATE` / `HDR_END_DATE`, …
   * the tree, the jobs that load each table, and the view SQL.
4. Switch **Direction** to *Downstream* to see every report column that depends on it.

## Step 10 (optional): refresh the lineage

**Button on the page.** Add a button `Refresh lineage` (Action: Submit Page) and a
**Process** (Type: Execute Code, server-side condition: *When Button Pressed*):

```sql
lin_engine.run(p_run_label => 'APEX ' || :APP_USER);
```

Then a **Success Message**: `Lineage refreshed.` The run takes a few seconds to minutes
depending on the number of views.

**Nightly job (recommended).** Run in SQL Developer:

```sql
begin
  dbms_scheduler.create_job(
    job_name        => 'LIN_ENGINE_NIGHTLY',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'begin lin_engine.run(p_run_label => ''nightly''); end;',
    start_date      => systimestamp,
    repeat_interval => 'FREQ=DAILY;BYHOUR=6;BYMINUTE=0',
    enabled         => true);
end;
/
```

(needs the `CREATE JOB` privilege)

## Step 11 (optional): more pages

| Page | Region type | Source |
|---|---|---|
| Job dependencies | Interactive Report | `select * from lin_job_dep where run_id = (select run_id from lin_v_latest_run)` |
| Object catalogue | Interactive Report | `select * from lin_v_nodes` (filter `node_class` = ROOT / TERMINAL) |
| Calculated columns | Interactive Report | `select * from lin_v_apex_column_calc where transform_type in ('CALCULATED','CASE','AGGREGATE','WINDOW')` |
| Data-quality check | Interactive Report | `select * from lin_v_column_lineage where resolution in ('AMBIGUOUS','UNRESOLVED')` |
| Job groups | Interactive Report | `select * from lin_v_group_node_class` |

Link the Object catalogue to page 1: column link → page 1, set `P1_OBJECT` = `#NODE_NAME#`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ORA-00942: table or view does not exist` in a region | The application parsing schema is not the lineage schema (Step 1). |
| Object LOV is empty | No completed run, or `07_apex_support.sql` not installed (Step 0). |
| Column list does not change when the object changes | `P1_COLUMN` → Cascading LOV Parent Item = `P1_OBJECT`. |
| Reports stay empty after selecting | Check *Page Items to Submit* on each region, or use the Submit button. |
| `ORA-04068` after recompiling the packages | Re-run the page (new session) — package state was reset. |
