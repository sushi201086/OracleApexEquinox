# Book_Jobs Lineage Engine

Object- and column-level lineage for the `Book_Jobs` ETL metadata table:
which view loads which table, which job depends on which, and **how every
column is calculated**, traced through any number of jobs and view layers.

| Piece | Where | What it does |
|---|---|---|
| Lineage repository | `sql/01_lineage_schema.sql` | Tables that store runs, jobs, groups, edges, nodes, job dependencies, view DDL, syntax trees and column lineage |
| `BOOK_JOBS` + loader | `sql/02_book_jobs_table.sql` | Metadata table (same columns as the sheet) and an `APEX_DATA_PARSER` .xlsx loader |
| **`LIN_SQL_PARSER`** | `sql/03_lin_sql_parser.pks/.pkb` | A SQL "tree sitter" in PL/SQL: tokenizer, a fault-tolerant recursive-descent parser that builds a syntax tree, then object and column-lineage extraction |
| **`LIN_ENGINE`** | `sql/04_lin_engine.pks/.pkb` | Lineage engine: business rules, view capture, node classification, DAG levels, job dependencies, column and object traces |
| View DDL helper | `sql/05_view_extraction.sql` | `ALL_VIEWS` / `USER_VIEWS` / `TO_LOB` / `DBMS_METADATA` / `ALL_DEPENDENCIES` / `INFORMATION_SCHEMA` queries |
| Reports | `sql/06_lineage_reports.sql` | Ready-made questions: roots, terminals, impact analysis, column traces, syntax-tree browsing, run diff |
| Python edition | `python/lineage_engine.py` | Reads the Excel sheet offline and applies the same rules. Writes CSV, Mermaid diagrams, the `BOOK_JOBS` load script and a view-DDL extraction script |
| Tests | `tests/` | `test_engine.sql` (30 assertions against a mock schema) and `test_lineage_engine.py` (pytest) |

## Quick start (Oracle)

```sql
-- 1. install (any schema with CREATE TABLE/VIEW/SEQUENCE/PROCEDURE)
@install.sql

-- 2. load the sheet into BOOK_JOBS (pick one)
@data/output/book_jobs_load.sql                 -- generated from data/book_job.xlsx
exec load_book_jobs_xlsx(:xlsx_blob)            -- APEX_DATA_PARSER (APEX installed)

-- 3. run the engine in the schema that owns the ETL tables/views
exec lin_engine.run                              -- prints a summary
-- or: select lin_engine.run(p_owner => 'BOOKINGS', p_run_label => 'nightly') from dual;

-- 4. ask questions
select * from table(lin_engine.trace_column('SNAP_BKG', 'TCV_USD'));            -- how is it calculated?
select * from table(lin_engine.trace_column('SRC_FX_RATE', 'RATE', 'DOWNSTREAM'));
select * from table(lin_engine.trace_object('RPT_DAILY_LIST', 'UPSTREAM'));
select * from lin_v_nodes where node_class = 'ROOT';
```

`LIN_ENGINE.RUN` parameters: `p_source_table` (default `BOOK_JOBS`),
`p_owner` (schema of the ETL objects), `p_capture_views` (read and parse
view definitions, default `true`), `p_view_depth` (view layers to walk
upstream, default 25), `p_use_dependencies` (add `ALL_DEPENDENCIES` edges the
parser did not report), `p_save_ast` (store syntax trees).

Every run is kept under its own `RUN_ID`. The `LIN_V_*` views always show the
latest completed run, and report 9 in `06_lineage_reports.sql` diffs two runs.

## Quick start (Python, no database)

```bash
pip install openpyxl
python python/lineage_engine.py data/book_job.xlsx --out data/output
# with view definitions exported from the DB (OWNER,VIEW_NAME,TEXT):
python python/lineage_engine.py data/book_job.xlsx --out data/output --views views.csv
```

Outputs in `data/output/`: `jobs.csv`, `job_groups.csv`, `job_objects.csv`,
`edges.csv`, `nodes.csv`, `job_deps.csv`, `mermaid/<group>.mmd` (one
flowchart per job group), `book_jobs_load.sql` and `extract_view_ddl.sql`.
The extract script holds the `ALL_VIEWS` and `DBMS_METADATA` queries for the
298 view names found in the sheet. The Python and PL/SQL engines produce
identical edges, node classes, DAG levels and job dependencies; this was
checked on the real sheet and on the mock schema.

## How the business rules are implemented

| Rule | Implementation |
|---|---|
| **1. Inactive rows** | `LIN_ENGINE.IS_DISABLED` treats `Y`, `YES`, `TRUE`, `1`, `X`, `D`, `DEL`, `DELETED`, `DISABLED`, `INACTIVE` and `OFF` as inactive, ignoring case and spaces. Inactive jobs are kept in `LIN_JOB` with `IS_ACTIVE='N'` for audit, but they produce no edges, objects or lineage. |
| **2A. Standard load** (`SQL_STMT` empty) | Edge `SOURCE_OBJECT → TARGET_OBJECT`, `EDGE_ORIGIN='JOB_STANDARD'`. `ACTION_TYPE` comes from `UNIQUE_COL`: `APPEND` gives `LOAD_APPEND`, a column name gives `LOAD_KEYED` (stored as `LOAD_KEY`), empty gives `LOAD_REPLACE`. Objects referenced in `FILTER_CLAUSE` become `FILTER` inputs. Column lineage matches target and source columns by name through `ALL_TAB_COLUMNS`. |
| **2B. Custom SQL** | `LIN_SQL_PARSER` finds targets (`INSERT INTO`, `UPDATE`, `DELETE`, `MERGE INTO`, `TRUNCATE`, `CREATE … AS`) and every source in `FROM`, `JOIN`, `USING`, CTEs, inline views and scalar/`IN`/`EXISTS` subqueries. Each source gets `REF_CONTEXT = DATA` (feeds values) or `FILTER` (only used in `WHERE`/`HAVING`, e.g. `DELETE … WHERE x IN (SELECT … FROM LKP_A_PULL_VAR)`). For `BEGIN … END;` blocks the called procedures become `PROCEDURE` nodes, and DML embedded in the block is parsed too. If the parse fails or finds no target, the job falls back to `SOURCE_OBJECT`/`TARGET_OBJECT` with `PARSE_STATUS='FALLBACK'`. A `SOURCE_OBJECT` such as `SQL: CLEAR PULL MONTH OVERRIDE #1` is recognised as a label, not an object. |
| **3. Job hierarchy** | `JOB_NAMES` is split on `|` into `LIN_JOB_GROUP(group_name, group_pos, group_path)`. `LIN_V_GROUP_EDGES` and `LIN_V_GROUP_NODE_CLASS` give each group its own sub-graph with roots and terminals. `LIN_JOB_DEP.SAME_GROUP` flags dependencies that cross groups. |
| **4. Non-linear DAG** | Edges are stored as a graph, not a sequence. View definitions are captured recursively (`ALL_VIEWS.TEXT` through `TO_LOB`), parsed and added as `VIEW_DEF` edges, with `ALL_DEPENDENCIES` as a safety net. This is what links `TABLE_1 → VIEW_D → VIEW_E → job 5`. `LIN_JOB_DEP` walks through any number of view layers (`HOPS`). `DAG_LEVEL` is the longest path on the SCC-condensed graph, so the SCD cycle (`SCD_CON_DTL → STG_SCD_CON_S5_V → STG_SCD_CON_S5 → SCD_CON_DTL`) gets `IN_CYCLE='Y'` and the graph still levels as a DAG. `DEP_TYPE` separates `PRIOR_STEP` (the producer runs earlier in `JOB_NUM` order) from `PRIOR_CYCLE` (the consumer reads the previous run's data). |

### Node classification (`LIN_NODE`)

* `NODE_CLASS` is computed on the full graph, jobs plus view definitions:
  * `ROOT`: nothing upstream (source tables, external views)
  * `TERMINAL`: nothing downstream (final report tables and marts)
  * `INTERMEDIATE`: staging and transient tables and views
  * `ISOLATED`: only touched by maintenance SQL, for example `DELETE FROM LKP_M_MON_VAR_OVR`
* `JOB_NODE_CLASS` uses job edges only. `VIEW_ONLY` marks objects that are reached only through view definitions.
* `NODE_TYPE` comes from `ALL_OBJECTS` (`TYPE_SOURCE='DICTIONARY'`). When an object is not in the dictionary, a heuristic applies: a name ending in `_V` is a `VIEW`, `PROCEDURE` is a called program, and `PSEUDO` is a non-identifier such as `STATUS EMAIL`.

## The SQL tree sitter (`LIN_SQL_PARSER`)

```
SQL text ─► tokenizer ─► recursive-descent parser ─► syntax tree (LIN_AST_NODE)
                                    │
                                    ├─► object references (SOURCE/TARGET/CALL, DATA/FILTER)
                                    └─► query blocks + scopes ─► column lineage (LIN_COLUMN_LINEAGE)
```

* **Tokenizer:** handles Oracle quoting (`"Quoted"` identifiers, `'it''s'`,
  `q'[...]'`, `N'..'`), `--` and `/* */` comments and hints, bind and
  substitution variables, and multi-character operators. It reads CLOBs of
  any size in buffered chunks.
* **Parser:** like tree-sitter, it never aborts. Unknown syntax becomes a
  generic node and the status drops to `PARTIAL` instead of `FAILED`. It
  covers `WITH` (including column lists and recursive CTEs), set operators,
  ANSI and Oracle `(+)` joins, `LATERAL`, `PIVOT`, `CONNECT BY`, analytic
  `OVER (…)`, `WITHIN GROUP`, `KEEP`, `CASE`, `DECODE`, `CAST`, `EXTRACT`,
  `INTERVAL` and date literals, scalar and correlated subqueries, `INSERT`
  (single- and multi-table), `UPDATE` (including `SET (a,b) = (SELECT …)`),
  `DELETE`, `MERGE`, `CREATE [MATERIALIZED] VIEW` / `CREATE TABLE … AS`, and
  PL/SQL blocks.
* **Syntax tree:** each node has `NODE_ID`, `PARENT_ID`, `NODE_TYPE`,
  `NODE_NAME`, `START_POS`/`END_POS` (character range in
  `LIN_PARSE.SQL_TEXT`), `NODE_TEXT`, `DEPTH` and `SIBLING_SEQ`, the same
  model tree-sitter uses. Browse it with `CONNECT BY` (report 8), or without
  storing anything:
  `select * from table(lin_sql_parser.parse_tree('select …'))`.
* **Column resolution:** follows table aliases, outer scopes for correlated
  subqueries, CTE and inline-view outputs (including CTE column lists),
  `UNION` branches by position, and `SELECT *` / `t.*` (expanded through
  `ALL_TAB_COLUMNS`, or kept as a `*` pass-through when the dictionary is
  not available). It maps `INSERT` columns by position (explicit list or
  dictionary) and names view columns from the dictionary.

### Column lineage (`LIN_COLUMN_LINEAGE`)

One row per (target column, source column) pair:

| Column | Meaning |
|---|---|
| `EXPRESSION` | Source text that produces the target column, e.g. `round(d.amt * nvl(fx.rate, 1), 2)` |
| `TRANSFORM_TYPE` | `DIRECT`, `RENAME`, `CALCULATED`, `CASE` (`CASE`/`DECODE`), `AGGREGATE`, `WINDOW`, `CONSTANT`, `STAR`. Taken across hops, the strongest transformation wins: an aggregate read through a rename stays `AGGREGATE` |
| `REF_ROLE` | `VALUE` (feeds the value), `CONDITION` (used in a `CASE WHEN`), `WINDOW` (`PARTITION BY`/`ORDER BY`), `KEY` (the `UNIQUE_COL` of a keyed load) |
| `RESOLUTION` | `RESOLVED`, `DICTIONARY`, `VIA_STAR`, `UNEXPANDED`, `AMBIGUOUS`, `UNRESOLVED`, `CONSTANT` |
| `LINEAGE_ORIGIN` | `VIEW_DEF`, `JOB_SQL`, `JOB_STANDARD` |

`LIN_ENGINE.TRACE_COLUMN` walks these rows breadth first, visiting each
(object, column) pair once and passing through `*` rows. Example from the
mock schema in `tests/mock_schema.sql`:

```
RPT_DAILY_LIST_1C.TCV_USD <- RPT_DAILY_LIST_1C_V.TCV_USD   (job 87/187, DIRECT)
  <- SNAP_BKG.TCV_USD                                       (view, DIRECT)
  <- APP_SNAP_BKG_V.TCV_USD                                 (job 125 INSERT SELECT *)
  <- BKG_BASE_V.AMT_USD                                     sum(b.amt_usd)            AGGREGATE
  <- SCD_CON_DTL.AMT_USD                                    (view, DIRECT)
  <- APP_SCD_CON_DTL_V.AMT_USD                              (job 41 LOAD_APPEND)
  <- STG_SCD_CON_S5.AMT_USD                                 (view, DIRECT)
  <- STG_SCD_CON_S5_V.AMT_USD                               (job 35 LOAD_REPLACE)
  <- SRC_CONTRACT_DTL.AMT, SRC_FX_RATE.RATE                 round(d.amt * nvl(fx.rate, 1), 2)  CALCULATED
```

## What the sheet shows (`data/book_job.xlsx`)

| | |
|---|---|
| Rows / active / disabled | 406 / 375 / 31 |
| Standard loads (case A) | 280: 203 `LOAD_REPLACE`, 53 `LOAD_KEYED`, 24 `LOAD_APPEND` |
| Custom SQL (case B) | 95: 41 `DELETE`, 37 `INSERT_SELECT`, 11 `UPDATE`, 6 `PLSQL_CALL`. All parsed, no fallback |
| Job groups | 27 (`ALL`, `Daily Load`, `EOM Compare`, `Excel Pull`, `WD Snap`, …) |
| Graph from the sheet alone | 606 nodes, 354 edges: 305 roots, 281 terminals, 14 intermediates, 6 isolated |
| Distinct `*_V` sources | 298 views: their definitions hold the real upstream lineage, so run the engine where they live |

Things worth reviewing in the metadata:

* **Job 374** is labelled `SQL : INSERT INTO DAILY_RPT_PROD_UPLOAD_S21A`, but its `SQL_STMT` is a `DELETE`. Job 375 has the same label and holds the `INSERT`. The engine follows the SQL.
* **65 targets are written by more than one active job**, and 19 of them by jobs in different group paths. Examples: `LKP_A_PULL_VAR` (jobs 6 and 250), `LKP_M_MON_VAR` (1, 2, 259), `LKP_M_BKG_USR` (15, 16, 197), `RPT_DAILY_LIST_1C` (87, 187). `LIN_JOB_DEP.IS_LATEST_WRITER` and `DEP_TYPE` show which write a reader actually sees.
* **Self-referencing month roll-forwards** (`INSERT INTO LKP_M_CONTRACT_TYPE SELECT … FROM LKP_M_CONTRACT_TYPE`) are stored as self-loops (`IS_SELF_LOOP='Y'`). They are excluded from classification, so these tables show as `ISOLATED`.
* **Without view definitions** almost every job is a one-hop `*_V → table` load, which is why the sheet alone yields 305 roots. Running `LIN_ENGINE.RUN` in the schema that owns the views turns these into a connected multi-level DAG.

## Tests

```bash
python -m pytest tests                           # Python engine (12 tests)
sqlplus user/pwd@db @install.sql                 # from the repository root
sqlplus user/pwd@db @tests/test_engine.sql       # 30 assertions: rules, views, cycles, column lineage, AST
```

Both suites were run on Oracle Database 23ai Free (`gvenzl/oracle-free`).
The PL/SQL uses nothing newer than 12c (`CROSS APPLY`, `TEXT_VC`) and no APEX
dependency, except the optional `LOAD_BOOK_JOBS_XLSX`, which calls APEX
through dynamic SQL.

## Limitations

* Lineage is static: dynamic SQL inside called procedures (e.g. `CON_DL.SEND_CON_UPDATES`) is not followed. Only the call is recorded.
* `PIVOT`/`UNPIVOT` and `MODEL` outputs keep the pre-pivot columns.
* An unqualified column in a multi-table query is resolved through the dictionary. Without dictionary access it is stored as `AMBIGUOUS`.
* `PRIOR_STEP`/`PRIOR_CYCLE` assumes jobs run in `JOB_NUM` order inside a run.
