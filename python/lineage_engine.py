#!/usr/bin/env python3
"""
Book_Jobs lineage engine (offline / Python edition).

Reads the Book_Jobs Excel sheet (or a CSV export), applies the same rules as
the PL/SQL engine (sql/04_lin_engine_body.sql) and writes the results as CSV files:

    jobs.csv          every job with case type, action type, parse status
    job_groups.csv    JOB_NAMES exploded into (job, group, position, path)
    job_objects.csv   objects read / written by each job
    edges.csv         SOURCE -> TARGET edges with job metadata
    nodes.csv         ROOT / INTERMEDIATE / TERMINAL classification, DAG level
    job_deps.csv      job -> job dependencies (through view layers when known)
    mermaid/*.mmd     one Mermaid flowchart per job group

It also generates the two SQL scripts needed on the database side:

    book_jobs_load.sql      INSERTs that load the sheet into the BOOK_JOBS table
    extract_view_ddl.sql    queries returning the DDL of every view discovered

Optionally pass --views <csv> (OWNER,VIEW_NAME,TEXT exported with
sql/05_view_extraction.sql) to add view-definition edges, which resolves
"skipped" dependencies such as TABLE_1 -> VIEW_X -> job 5.

Only the standard library is required for CSV input; reading .xlsx needs
openpyxl (pip install openpyxl).

Usage:
    python lineage_engine.py ../data/book_job.xlsx --out ../data/output
    python lineage_engine.py ../data/book_job.xlsx --out ../data/output --views views.csv
"""
from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field

COLUMNS = ["JOB_NUM", "JOB_NAMES", "TARGET_OBJECT", "SOURCE_OBJECT", "UNIQUE_COL",
           "FILTER_CLAUSE", "SQL_STMT", "DISABLED_FLAG"]
DISABLED_VALUES = {"Y", "YES", "TRUE", "1", "X", "D", "DEL", "DELETED", "DISABLED", "INACTIVE", "OFF"}
IDENT_RE = re.compile(r"^[A-Z][A-Z0-9_$#]*(\.[A-Z][A-Z0-9_$#]*)?(@[A-Z0-9_$#.]+)?$")


# --------------------------------------------------------------------------
# Input
# --------------------------------------------------------------------------
def _clean(v):
    if v is None:
        return None
    if isinstance(v, float):
        if v != v:  # NaN
            return None
        return str(int(v)) if v.is_integer() else str(v)
    s = str(v).replace("_x000D_", "").replace("\r", "")
    return s.strip() or None


def read_jobs(path: str) -> list[dict]:
    if path.lower().endswith((".xlsx", ".xlsm")):
        try:
            import openpyxl
        except ImportError:
            sys.exit("Reading .xlsx needs openpyxl:  pip install openpyxl")
        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        ws = wb.worksheets[0]
        rows = ws.iter_rows(values_only=True)
        header = [str(h).strip().upper() if h is not None else "" for h in next(rows)]
        data = [dict(zip(header, r)) for r in rows]
    else:
        with open(path, newline="", encoding="utf-8-sig") as fh:
            data = [{k.strip().upper(): v for k, v in r.items()} for r in csv.DictReader(fh)]
    missing = [c for c in COLUMNS if c not in (data[0].keys() if data else COLUMNS)]
    if missing:
        sys.exit(f"Missing columns in {path}: {missing}")
    jobs = []
    for r in data:
        rec = {c: _clean(r.get(c)) for c in COLUMNS}
        if rec["JOB_NUM"] is None:
            continue
        rec["JOB_NUM"] = int(float(rec["JOB_NUM"]))
        jobs.append(rec)
    jobs.sort(key=lambda j: j["JOB_NUM"])
    return jobs


def is_disabled(flag) -> bool:
    return flag is not None and str(flag).strip().upper() in DISABLED_VALUES


def norm(name, owner=None):
    if name is None:
        return None
    n = re.sub(r"\s+", " ", str(name).replace('"', "").strip().upper())
    if owner and n.startswith(owner.upper() + "."):
        n = n[len(owner) + 1:]
    return n or None


def is_label(name) -> bool:
    return name is None or re.match(r"^\s*SQL\s*:", name, re.I) is not None


# --------------------------------------------------------------------------
# SQL tokenizer / object extractor (mirrors LIN_SQL_PARSER object rules)
# --------------------------------------------------------------------------
@dataclass
class Tok:
    type: str   # ID QID STR NUM OP ( ) , ; . BIND
    text: str

    @property
    def up(self):
        return self.text.upper() if self.type == "ID" else (self.text if self.type in "(),;." or self.type == "OP" else None)


def tokenize(sql: str) -> list[Tok]:
    toks, i, n = [], 0, len(sql)
    while i < n:
        c = sql[i]
        if c.isspace():
            i += 1
        elif sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j
        elif sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif c == "'" or (c in "nNqQ" and sql[i + 1:i + 2] == "'") or (c in "nN" and sql[i + 1:i + 2] in "qQ" and sql[i + 2:i + 3] == "'" and sql[i + 1:i + 2] != ""):
            j = i + (1 if c in "nN" else 0)
            if sql[j] in "qQ":
                open_d = sql[j + 2:j + 3]
                close_d = {"[": "]", "{": "}", "(": ")", "<": ">"}.get(open_d, open_d)
                k = sql.find(close_d + "'", j + 3)
                k = n - 1 if k < 0 else k + 1
            else:
                k = j + 1
                while k < n:
                    if sql[k] == "'":
                        if sql[k + 1:k + 2] == "'":
                            k += 2
                            continue
                        break
                    k += 1
            toks.append(Tok("STR", sql[i:k + 1]))
            i = k + 1
        elif c == '"':
            k = sql.find('"', i + 1)
            k = n if k < 0 else k
            toks.append(Tok("QID", sql[i + 1:k]))
            i = k + 1
        elif c.isdigit():
            m = re.match(r"\d+(\.\d+)?([eE][+-]?\d+)?", sql[i:])
            toks.append(Tok("NUM", m.group(0)))
            i += len(m.group(0))
        elif c.isalpha() or c in "_$#" or ord(c) > 127:
            m = re.match(r"[\w$#]+", sql[i:], re.UNICODE)
            toks.append(Tok("ID", m.group(0)))
            i += len(m.group(0))
        elif c == ":" and i + 1 < n and (sql[i + 1].isalnum() or sql[i + 1] == "_"):
            m = re.match(r":[\w$#]+", sql[i:])
            toks.append(Tok("BIND", m.group(0)))
            i += len(m.group(0))
        elif c in "(),;.":
            toks.append(Tok(c, c))
            i += 1
        else:
            two = sql[i:i + 2]
            if two in ("||", "<=", ">=", "<>", "!=", "^=", "=>", ":=", "**"):
                toks.append(Tok("OP", two))
                i += 2
            else:
                toks.append(Tok("OP", c))
                i += 1
    return toks


CLAUSE_STOP = {"WHERE", "GROUP", "HAVING", "ORDER", "UNION", "INTERSECT", "MINUS", "EXCEPT",
               "CONNECT", "START", "ON", "USING", "JOIN", "INNER", "LEFT", "RIGHT", "FULL",
               "CROSS", "NATURAL", "OUTER", "SET", "VALUES", "SELECT", "FROM", "WHEN", "THEN",
               "ELSE", "END", "FETCH", "OFFSET", "PIVOT", "UNPIVOT", "MODEL", "WINDOW", "FOR",
               "RETURNING", "LOG", "WITH", "PARTITION", "SAMPLE", "AS"}
FILTER_CLAUSES = {"WHERE", "HAVING", "CONNECT", "START"}


@dataclass
class ParseResult:
    stmt_type: str = "UNKNOWN"
    status: str = "OK"
    message: str | None = None
    targets: list = field(default_factory=list)
    sources: list = field(default_factory=list)   # (name, context)
    calls: list = field(default_factory=list)


def parse_sql(sql: str, owner: str | None = None) -> ParseResult:
    res = ParseResult()
    try:
        toks = tokenize(sql)
    except Exception as exc:  # pragma: no cover - defensive
        res.status, res.message = "FAILED", f"tokenize: {exc}"
        return res
    if not toks:
        res.status, res.message = "FAILED", "empty"
        return res

    def up(k):
        return toks[k].up if 0 <= k < len(toks) else None

    def read_name(k):
        """dotted name starting at k -> (name, next index)"""
        if k >= len(toks) or toks[k].type not in ("ID", "QID"):
            return None, k
        parts = [toks[k].text.upper() if toks[k].type == "ID" else toks[k].text]
        k += 1
        while k + 1 < len(toks) and toks[k].type == "." and toks[k + 1].type in ("ID", "QID"):
            parts.append(toks[k + 1].text.upper() if toks[k + 1].type == "ID" else toks[k + 1].text)
            k += 2
        return norm(".".join(parts), owner), k

    first = up(0)
    if first in ("BEGIN", "DECLARE", "CALL", "EXEC", "EXECUTE"):
        res.stmt_type = "PLSQL"
        at_start = True
        k = 0
        while k < len(toks):
            u = up(k)
            if u in ("BEGIN", "DECLARE", "THEN", "ELSE", "LOOP", "IS", "AS") or toks[k].type == ";":
                at_start, k = True, k + 1
                continue
            if at_start and u in ("INSERT", "UPDATE", "DELETE", "MERGE"):
                end = next((x for x in range(k, len(toks)) if toks[x].type == ";"), len(toks))
                inner = parse_sql(" ".join(t.text if t.type != "QID" else f'"{t.text}"' for t in toks[k:end]), owner)
                res.targets += inner.targets
                res.sources += inner.sources
                k, at_start = end, False
                continue
            if at_start and toks[k].type in ("ID", "QID") and u not in (
                    "END", "IF", "ELSIF", "WHILE", "FOR", "RETURN", "NULL", "COMMIT", "ROLLBACK",
                    "EXCEPTION", "WHEN", "RAISE", "EXIT", "OPEN", "CLOSE", "FETCH", "SELECT", "CASE"):
                name, k2 = read_name(k)
                if k2 < len(toks) and toks[k2].type in ("(", ";"):
                    res.calls.append(name)
                k, at_start = max(k2, k + 1), False
                continue
            k, at_start = k + 1, False
        return res

    ctes = set()
    # CTE names: WITH name [(cols)] AS (
    for k, t in enumerate(toks):
        if t.type in ("ID", "QID") and up(k + 1) == "AS" and up(k + 2) == "(" and (
                up(k - 1) in ("WITH", ",") or up(k - 1) == ")"):
            ctes.add(t.text.upper())
        if t.type in ("ID", "QID") and up(k + 1) == "(" and up(k - 1) in ("WITH", ","):
            # name (c1, c2) AS (
            d, j = 0, k + 1
            while j < len(toks):
                if toks[j].type == "(":
                    d += 1
                elif toks[j].type == ")":
                    d -= 1
                    if d == 0:
                        break
                j += 1
            if up(j + 1) == "AS" and up(j + 2) == "(":
                ctes.add(t.text.upper())

    clause = [None]          # clause per paren depth
    in_from = [False]        # FROM list still open at this depth (survives JOIN ... ON)
    target_pos = -1
    if first == "INSERT":
        res.stmt_type = "INSERT"
        k = 1
        if up(k) in ("ALL", "FIRST"):
            for x in range(len(toks)):
                if up(x) == "INTO":
                    name, _ = read_name(x + 1)
                    if name:
                        res.targets.append(name)
        else:
            if up(k) == "INTO":
                k += 1
            name, target_pos = read_name(k)
            res.targets.append(name)
    elif first == "UPDATE":
        res.stmt_type = "UPDATE"
        name, target_pos = read_name(1)
        res.targets.append(name)
    elif first == "DELETE":
        res.stmt_type = "DELETE"
        k = 2 if up(1) == "FROM" else 1
        name, target_pos = read_name(k)
        res.targets.append(name)
    elif first == "MERGE":
        res.stmt_type = "MERGE"
        name, target_pos = read_name(2 if up(1) == "INTO" else 1)
        res.targets.append(name)
    elif first == "TRUNCATE":
        res.stmt_type = "TRUNCATE"
        name, target_pos = read_name(2 if up(1) == "TABLE" else 1)
        res.targets.append(name)
    elif first in ("SELECT", "WITH", "("):
        res.stmt_type = "SELECT"
    elif first == "CREATE":
        res.stmt_type = "CREATE"
        for x in range(len(toks)):
            if up(x) in ("VIEW", "TABLE"):
                name, target_pos = read_name(x + 1)
                res.targets.append(name)
                break
    else:
        res.status, res.message = "FAILED", f"unsupported statement {first}"
        return res

    expect_table = False
    k = max(target_pos, 0) if res.stmt_type in ("UPDATE", "DELETE", "MERGE", "TRUNCATE") else 0
    while k < len(toks):
        t, u = toks[k], up(k)
        if t.type == "(":
            clause.append(None)
            in_from.append(False)
            expect_table = False
            k += 1
            continue
        if t.type == ")":
            if len(clause) > 1:
                clause.pop()
                in_from.pop()
            k += 1
            continue
        if u in ("FROM", "JOIN", "USING", "APPLY"):
            clause[-1] = "FROM"
            in_from[-1] = True
            expect_table = True
            k += 1
            continue
        if u in FILTER_CLAUSES:
            clause[-1] = u
            in_from[-1] = False
            expect_table = False
            k += 1
            continue
        if u in ("SELECT", "SET", "VALUES", "ON", "GROUP", "ORDER", "INTO"):
            clause[-1] = u
            in_from[-1] = in_from[-1] and u == "ON"
            expect_table = False
            k += 1
            continue
        if t.type == "," and in_from[-1]:
            expect_table = True
            k += 1
            continue
        if expect_table and t.type in ("ID", "QID") and u not in ("LATERAL", "TABLE", "ONLY"):
            name, k2 = read_name(k)
            expect_table = False
            if k2 < len(toks) and toks[k2].type == "(":
                k = k2            # table function
                continue
            if name and name not in ctes and name not in ("DUAL", "SYS.DUAL"):
                ctx = "FILTER" if any(c in FILTER_CLAUSES for c in clause[:-1]) else "DATA"
                if (name, ctx) not in res.sources:
                    res.sources.append((name, ctx))
            k = k2
            # skip alias
            if k < len(toks) and toks[k].type in ("ID", "QID") and (up(k) not in CLAUSE_STOP):
                k += 1
            continue
        expect_table = False if t.type not in ("ID", "QID") or u in ("LATERAL", "TABLE", "ONLY") else expect_table
        k += 1
    res.targets = [x for x in res.targets if x]
    if not res.targets and res.stmt_type not in ("SELECT",):
        res.status, res.message = "FAILED", "no target found"
    return res


# --------------------------------------------------------------------------
# Engine
# --------------------------------------------------------------------------
class Engine:
    def __init__(self, jobs, owner=None, views=None):
        self.jobs = jobs
        self.owner = owner
        self.views = views or {}           # VIEW_NAME -> text
        self.edges = []                    # dicts
        self._edge_keys = set()
        self.job_objects = []
        self._jo_keys = set()
        self.groups = []
        self.nodes = {}
        self.deps = []

    def add_job_object(self, job, obj, role, ctx, origin):
        key = (job, obj, role, ctx)
        if obj and key not in self._jo_keys:
            self._jo_keys.add(key)
            self.job_objects.append(dict(JOB_NUM=job, OBJECT_NAME=obj, OBJECT_ROLE=role,
                                         REF_CONTEXT=ctx, DERIVED_FROM=origin))

    def add_edge(self, src, tgt, job, names, action, origin, ctx):
        key = (src, tgt, job, origin, ctx)
        if not src or not tgt or key in self._edge_keys:
            return
        self._edge_keys.add(key)
        self.edges.append(dict(SOURCE_NODE=src, TARGET_NODE=tgt, JOB_NUM=job, JOB_NAMES=names,
                               ACTION_TYPE=action, EDGE_ORIGIN=origin, REF_CONTEXT=ctx,
                               IS_SELF_LOOP="Y" if src == tgt else "N"))

    # ---- steps 1-3 --------------------------------------------------------
    def process_jobs(self):
        for seq, j in enumerate(self.jobs, 1):
            j["EXEC_SEQ"] = seq
            j["IS_ACTIVE"] = "N" if is_disabled(j["DISABLED_FLAG"]) else "Y"
            names = j["JOB_NAMES"]
            if names:
                parts = [p.strip() for p in names.strip("|").split("|") if p.strip()]
                for pos, g in enumerate(parts, 1):
                    self.groups.append(dict(JOB_NUM=j["JOB_NUM"], GROUP_NAME=g, GROUP_POS=pos,
                                            GROUP_PATH="|".join(parts[:pos])))
            if j["IS_ACTIVE"] != "Y":
                j.update(CASE_TYPE=None, ACTION_TYPE=None, PARSE_STATUS=None, PARSE_MESSAGE=None)
                continue
            tgt = norm(j["TARGET_OBJECT"], self.owner)
            src = None if is_label(j["SOURCE_OBJECT"]) else norm(j["SOURCE_OBJECT"], self.owner)
            sql = j["SQL_STMT"]
            if sql and not re.match(r"^\s*(BEGIN|DECLARE)", sql, re.I):
                sql = re.sub(r";\s*$", "", sql)
            jn = j["JOB_NUM"]
            if not sql:
                uc = (j["UNIQUE_COL"] or "").upper()
                action = "LOAD_APPEND" if uc == "APPEND" else ("LOAD_KEYED" if uc else "LOAD_REPLACE")
                self._meta(jn, names, tgt, src, action, "JOB_STANDARD", "METADATA")
                if j["FILTER_CLAUSE"] and src:
                    for name, _ in parse_sql(f"select * from {src} where {j['FILTER_CLAUSE']}", self.owner).sources:
                        if name != src:
                            self.add_job_object(jn, name, "SOURCE", "FILTER", "METADATA")
                            self.add_edge(name, tgt, jn, names, action, "JOB_STANDARD", "FILTER")
                j.update(CASE_TYPE="A_STANDARD", ACTION_TYPE=action, PARSE_STATUS="N_A", PARSE_MESSAGE=None)
                continue
            r = parse_sql(sql, self.owner)
            action = {"INSERT": "INSERT_SELECT" if r.sources else "INSERT_VALUES", "UPDATE": "UPDATE",
                      "DELETE": "DELETE", "MERGE": "MERGE", "TRUNCATE": "TRUNCATE",
                      "PLSQL": "PLSQL_CALL", "SELECT": "SELECT"}.get(r.stmt_type, "UNKNOWN")
            status, msg = r.status, r.message
            if r.status == "FAILED" or (not r.targets and r.stmt_type != "PLSQL"):
                status = "FALLBACK"
                self._meta(jn, names, tgt, src, action, "JOB_FALLBACK", "FALLBACK")
            elif r.stmt_type == "PLSQL":
                if tgt:
                    self.add_job_object(jn, tgt, "TARGET", "DATA", "METADATA")
                for c in r.calls:
                    self.add_job_object(jn, c, "CALL", "DATA", "SQL_PARSE")
                    self.add_edge(c, tgt, jn, names, action, "JOB_PLSQL", "DATA")
                for t in r.targets:
                    self.add_job_object(jn, t, "TARGET", "DATA", "SQL_PARSE")
                for s, ctx in r.sources:
                    self.add_job_object(jn, s, "SOURCE", ctx, "SQL_PARSE")
                    self.add_edge(s, tgt, jn, names, action, "JOB_SQL", ctx)
                if src:
                    self.add_job_object(jn, src, "SOURCE", "DATA", "METADATA")
                    self.add_edge(src, tgt, jn, names, action, "JOB_PLSQL", "DATA")
            else:
                for t in r.targets:
                    self.add_job_object(jn, t, "TARGET", "DATA", "SQL_PARSE")
                for s, ctx in r.sources:
                    self.add_job_object(jn, s, "SOURCE", ctx, "SQL_PARSE")
                    for t in r.targets:
                        self.add_edge(s, t, jn, names, action, "JOB_SQL", ctx)
                if tgt and r.targets and r.targets[0] != tgt:
                    msg = f"TARGET_OBJECT {tgt} differs from SQL target {r.targets[0]}"
            j.update(CASE_TYPE="B_SQL", ACTION_TYPE=action, PARSE_STATUS=status, PARSE_MESSAGE=msg)

    def _meta(self, jn, names, tgt, src, action, origin, derived):
        if tgt:
            self.add_job_object(jn, tgt, "TARGET", "DATA", derived)
        if src:
            self.add_job_object(jn, src, "SOURCE", "DATA", derived)
            self.add_edge(src, tgt, jn, names, action, origin, "DATA")

    # ---- step 4: view definitions ------------------------------------------
    def process_views(self):
        if not self.views:
            return
        done, frontier = set(), True
        while frontier:
            frontier = False
            nodes = {e["SOURCE_NODE"] for e in self.edges} | {e["TARGET_NODE"] for e in self.edges}
            for v in sorted(nodes):
                if v in self.views and v not in done:
                    done.add(v)
                    frontier = True
                    r = parse_sql(self.views[v], self.owner)
                    for s, ctx in r.sources:
                        self.add_edge(s, v, None, None, "VIEW", "VIEW_DEF", ctx)

    # ---- step 5: nodes / levels / deps --------------------------------------
    def build_nodes(self):
        calls = {o["OBJECT_NAME"] for o in self.job_objects if o["OBJECT_ROLE"] == "CALL"}
        names = {e["SOURCE_NODE"] for e in self.edges} | {e["TARGET_NODE"] for e in self.edges} \
            | {o["OBJECT_NAME"] for o in self.job_objects}
        real = [e for e in self.edges if e["IS_SELF_LOOP"] == "N"]
        ins, outs, jins, jouts = (defaultdict(set) for _ in range(4))
        for e in real:
            ins[e["TARGET_NODE"]].add(e["SOURCE_NODE"])
            outs[e["SOURCE_NODE"]].add(e["TARGET_NODE"])
            if e["JOB_NUM"] is not None:
                jins[e["TARGET_NODE"]].add(e["SOURCE_NODE"])
                jouts[e["SOURCE_NODE"]].add(e["TARGET_NODE"])
        writers, readers = defaultdict(set), defaultdict(set)
        for o in self.job_objects:
            if o["OBJECT_ROLE"] == "TARGET":
                writers[o["OBJECT_NAME"]].add(o["JOB_NUM"])
            elif o["OBJECT_ROLE"] == "SOURCE":
                readers[o["OBJECT_NAME"]].add(o["JOB_NUM"])

        def klass(i, o):
            return "ISOLATED" if not i and not o else "ROOT" if not i else "TERMINAL" if not o else "INTERMEDIATE"

        for n in sorted(names):
            if n in calls:
                ntype = "PROCEDURE"
            elif not IDENT_RE.match(n):
                ntype = "PSEUDO"
            elif n in self.views or n.endswith("_V"):
                ntype = "VIEW"
            else:
                ntype = "TABLE"
            w, r = writers.get(n, set()), readers.get(n, set())
            jc = "VIEW_ONLY" if not w and not r and not jins[n] and not jouts[n] else klass(jins[n], jouts[n])
            self.nodes[n] = dict(NODE_NAME=n, NODE_TYPE=ntype, TYPE_SOURCE="DICTIONARY" if n in self.views else "HEURISTIC",
                                 NODE_CLASS=klass(ins[n], outs[n]), JOB_NODE_CLASS=jc,
                                 IN_DEGREE=len(ins[n]), OUT_DEGREE=len(outs[n]),
                                 JOB_IN_DEGREE=len(jins[n]), JOB_OUT_DEGREE=len(jouts[n]),
                                 DAG_LEVEL=None, IN_CYCLE="N", WRITER_JOBS=len(w), READER_JOBS=len(r),
                                 FIRST_WRITER_JOB=min(w) if w else None, LAST_WRITER_JOB=max(w) if w else None)
        self._levels(outs)

    def _levels(self, outs):
        """Tarjan SCC (iterative) + longest path on the condensation."""
        names = sorted(self.nodes)
        index, low, onstack, stack, comp = {}, {}, set(), [], {}
        counter = 0
        ncomp = 0
        for root in names:
            if root in index:
                continue
            work = [(root, iter(sorted(outs[root])))]
            index[root] = low[root] = counter
            counter += 1
            stack.append(root)
            onstack.add(root)
            while work:
                v, it = work[-1]
                advanced = False
                for w in it:
                    if w not in index:
                        index[w] = low[w] = counter
                        counter += 1
                        stack.append(w)
                        onstack.add(w)
                        work.append((w, iter(sorted(outs[w]))))
                        advanced = True
                        break
                    if w in onstack:
                        low[v] = min(low[v], index[w])
                if advanced:
                    continue
                work.pop()
                if work:
                    low[work[-1][0]] = min(low[work[-1][0]], low[v])
                if low[v] == index[v]:
                    ncomp += 1
                    while True:
                        w = stack.pop()
                        onstack.discard(w)
                        comp[w] = ncomp
                        if w == v:
                            break
        size = defaultdict(int)
        for v, c in comp.items():
            size[c] += 1
        cadj, indeg = defaultdict(set), defaultdict(int)
        for v in names:
            for w in outs[v]:
                a, b = comp[v], comp[w]
                if a != b and b not in cadj[a]:
                    cadj[a].add(b)
                    indeg[b] += 1
        level = {c: 0 for c in size}
        queue = [c for c in size if indeg[c] == 0]
        while queue:
            c = queue.pop()
            for d in cadj[c]:
                level[d] = max(level[d], level[c] + 1)
                indeg[d] -= 1
                if indeg[d] == 0:
                    queue.append(d)
        for v in names:
            self.nodes[v]["DAG_LEVEL"] = level[comp[v]]
            self.nodes[v]["IN_CYCLE"] = "Y" if size[comp[v]] > 1 else "N"

    def job_dependencies(self):
        seq = {j["JOB_NUM"]: j["EXEC_SEQ"] for j in self.jobs}
        groups = defaultdict(set)
        for g in self.groups:
            groups[g["JOB_NUM"]].add(g["GROUP_NAME"])
        writers = defaultdict(set)
        for o in self.job_objects:
            if o["OBJECT_ROLE"] == "TARGET":
                writers[o["OBJECT_NAME"]].add(o["JOB_NUM"])
        vparents = defaultdict(set)
        for e in self.edges:
            if e["JOB_NUM"] is None and e["IS_SELF_LOOP"] == "N":
                vparents[e["TARGET_NODE"]].add(e["SOURCE_NODE"])
        found = {}
        for o in self.job_objects:
            if o["OBJECT_ROLE"] != "SOURCE":
                continue
            job, read = o["JOB_NUM"], o["OBJECT_NAME"]
            frontier, seen, hops = {read}, {read}, 0
            while frontier and hops <= 30:
                nxt = set()
                for obj in frontier:
                    if writers.get(obj):
                        for p in writers[obj]:
                            if p != job:
                                key = (job, p, obj, read)
                                found[key] = min(found.get(key, hops), hops)
                    else:
                        for par in vparents.get(obj, ()):
                            if par not in seen:
                                seen.add(par)
                                nxt.add(par)
                frontier, hops = nxt, hops + 1
        latest = {}
        for (job, p, obj, read) in found:
            if seq[p] < seq[job]:
                k = (job, obj)
                latest[k] = max(latest.get(k, -1), seq[p])
        for (job, p, obj, read), hops in sorted(found.items()):
            self.deps.append(dict(JOB_NUM=job, DEPENDS_ON_JOB=p, VIA_OBJECT=obj, READ_OBJECT=read, HOPS=hops,
                                  DEP_TYPE="PRIOR_STEP" if seq[p] < seq[job] else "PRIOR_CYCLE",
                                  IS_LATEST_WRITER="Y" if latest.get((job, obj)) == seq[p] else "N",
                                  SAME_GROUP="Y" if groups[job] & groups[p] else "N"))

    def run(self):
        self.process_jobs()
        self.process_views()
        self.build_nodes()
        self.job_dependencies()
        return self


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
def write_csv(path, rows, cols=None):
    cols = cols or (list(rows[0].keys()) if rows else [])
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def sql_literal(v):
    if v is None:
        return "null"
    s = str(v)
    if "]'" not in s:
        return "q'[" + s + "]'"
    return "'" + s.replace("'", "''") + "'"


def write_load_sql(path, jobs):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("-- Generated by python/lineage_engine.py from the Book_Jobs sheet\n")
        fh.write("set define off\nset feedback off\ntruncate table book_jobs;\n\n")
        for j in jobs:
            sql = j["SQL_STMT"]
            sql_expr = "null" if sql is None else ("to_clob(" + sql_literal(sql) + ")")
            fh.write("insert into book_jobs (job_num, job_names, target_object, source_object, unique_col, "
                     "filter_clause, sql_stmt, disabled_flag) values (\n  "
                     + ", ".join([str(j["JOB_NUM"]), sql_literal(j["JOB_NAMES"]), sql_literal(j["TARGET_OBJECT"]),
                                  sql_literal(j["SOURCE_OBJECT"]), sql_literal(j["UNIQUE_COL"]),
                                  sql_literal(j["FILTER_CLAUSE"]), sql_expr, sql_literal(j["DISABLED_FLAG"])])
                     + ");\n")
        fh.write("\ncommit;\nset feedback on\nselect count(*) book_jobs_rows from book_jobs;\n")


def write_view_sql(path, views, owner):
    own = f"'{owner.upper()}'" if owner else "sys_context('USERENV','CURRENT_SCHEMA')"
    chunks = [views[i:i + 500] for i in range(0, len(views), 500)] or [[]]
    in_list = "\n     or ".join(
        "view_name in (" + ",\n                     ".join(f"'{v}'" for v in c) + ")" for c in chunks)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"""-- Generated by python/lineage_engine.py
-- DDL / definitions of the {len(views)} views discovered in the Book_Jobs lineage.
set define off
set long 2000000 longchunksize 32767 pagesize 0 linesize 32767 trimspool on

-- 1) Oracle data dictionary (query text). TEXT is a LONG: TEXT_VC holds the first 4000 chars.
select owner, view_name, text_length, text_vc
from   all_views
where  owner = {own}
and   ({in_list})
order  by view_name;

-- 2) Full CREATE VIEW statements (DBMS_METADATA)
exec dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'SQLTERMINATOR', true);
exec dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'PRETTY', true);
select dbms_metadata.get_ddl('VIEW', view_name, owner) ddl
from   all_views
where  owner = {own}
and   ({in_list})
order  by view_name;

-- 3) Views that do not exist in this schema (renamed / dropped / other owner)
select v.column_value missing_view
from   table(sys.odcivarchar2list({", ".join(f"'{v}'" for v in views[:999]) or "null"})) v
where  not exists (select 1 from all_views a where a.owner = {own} and a.view_name = v.column_value);

-- 4) ANSI information schema equivalent (PostgreSQL / SQL Server / MySQL / Snowflake)
-- select table_schema, table_name, view_definition
-- from   information_schema.views
-- where  table_name in ({", ".join(f"'{v}'" for v in views[:50])}{", ..." if len(views) > 50 else ""});
""")


def write_mermaid(out_dir, eng):
    os.makedirs(out_dir, exist_ok=True)
    by_group = defaultdict(list)
    job_groups = defaultdict(list)
    for g in eng.groups:
        job_groups[g["JOB_NUM"]].append(g["GROUP_NAME"])
    for e in eng.edges:
        if e["JOB_NUM"] is not None and e["IS_SELF_LOOP"] == "N":
            for g in job_groups.get(e["JOB_NUM"], ["(no group)"]):
                by_group[g].append(e)
    ids = {}

    def nid(n):
        if n not in ids:
            ids[n] = f"n{len(ids)}"
        return ids[n]

    style = {"ROOT": "fill:#e3f2fd,stroke:#1565c0", "TERMINAL": "fill:#e8f5e9,stroke:#2e7d32",
             "INTERMEDIATE": "fill:#fff8e1,stroke:#f9a825", "ISOLATED": "fill:#eeeeee,stroke:#757575"}
    for g, edges in sorted(by_group.items()):
        lines = ["flowchart LR"]
        seen_nodes = set()
        for e in edges:
            for n in (e["SOURCE_NODE"], e["TARGET_NODE"]):
                if n not in seen_nodes:
                    seen_nodes.add(n)
                    lines.append(f'  {nid(n)}["{n}"]')
            arrow = "-.->" if e["REF_CONTEXT"] == "FILTER" else "-->"
            lines.append(f'  {nid(e["SOURCE_NODE"])} {arrow}|{e["JOB_NUM"]} {e["ACTION_TYPE"]}| {nid(e["TARGET_NODE"])}')
        for n in seen_nodes:
            cls = eng.nodes[n]["JOB_NODE_CLASS"]
            if cls in style:
                lines.append(f"  style {nid(n)} {style[cls]}")
        fname = re.sub(r"[^A-Za-z0-9]+", "_", g).strip("_") or "group"
        with open(os.path.join(out_dir, f"{fname}.mmd"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="Book_Jobs .xlsx or .csv")
    ap.add_argument("--out", default="output", help="output directory")
    ap.add_argument("--owner", default=None, help="schema owner prefix to strip from object names")
    ap.add_argument("--views", default=None, help="CSV with OWNER,VIEW_NAME,TEXT to add view-definition edges")
    args = ap.parse_args(argv)

    jobs = read_jobs(args.input)
    views = {}
    if args.views:
        csv.field_size_limit(sys.maxsize)
        with open(args.views, newline="", encoding="utf-8-sig") as fh:
            for r in csv.DictReader(fh):
                r = {k.upper(): v for k, v in r.items()}
                views[norm(r["VIEW_NAME"], args.owner)] = r.get("TEXT") or r.get("VIEW_TEXT") or ""
    eng = Engine(jobs, args.owner, views).run()

    os.makedirs(args.out, exist_ok=True)
    write_csv(os.path.join(args.out, "jobs.csv"), jobs,
              ["JOB_NUM", "EXEC_SEQ", "JOB_NAMES", "TARGET_OBJECT", "SOURCE_OBJECT", "UNIQUE_COL",
               "DISABLED_FLAG", "IS_ACTIVE", "CASE_TYPE", "ACTION_TYPE", "PARSE_STATUS", "PARSE_MESSAGE", "SQL_STMT"])
    write_csv(os.path.join(args.out, "job_groups.csv"), eng.groups)
    write_csv(os.path.join(args.out, "job_objects.csv"), eng.job_objects)
    write_csv(os.path.join(args.out, "edges.csv"), eng.edges)
    write_csv(os.path.join(args.out, "nodes.csv"), [eng.nodes[n] for n in sorted(eng.nodes)])
    write_csv(os.path.join(args.out, "job_deps.csv"), eng.deps)
    write_mermaid(os.path.join(args.out, "mermaid"), eng)
    write_load_sql(os.path.join(args.out, "book_jobs_load.sql"), jobs)
    view_names = sorted(n for n, v in eng.nodes.items() if v["NODE_TYPE"] == "VIEW" and "." not in n)
    write_view_sql(os.path.join(args.out, "extract_view_ddl.sql"), view_names, args.owner)

    active = [j for j in jobs if j["IS_ACTIVE"] == "Y"]
    cls = defaultdict(int)
    for n in eng.nodes.values():
        cls[n["NODE_CLASS"]] += 1
    print(f"jobs read={len(jobs)} active={len(active)} disabled={len(jobs) - len(active)}")
    print(f"case A={sum(j['CASE_TYPE'] == 'A_STANDARD' for j in active)} "
          f"case B={sum(j['CASE_TYPE'] == 'B_SQL' for j in active)} "
          f"fallback={sum(j['PARSE_STATUS'] == 'FALLBACK' for j in active)}")
    print(f"nodes={len(eng.nodes)} edges={len(eng.edges)} job deps={len(eng.deps)} views referenced={len(view_names)}")
    print("node classes: " + ", ".join(f"{k}={v}" for k, v in sorted(cls.items())))
    print(f"output written to {os.path.abspath(args.out)}")


if __name__ == "__main__":
    main()
