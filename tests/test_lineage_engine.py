"""pytest tests for python/lineage_engine.py  (run: python -m pytest tests)"""
import csv
import os
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "python"))

import lineage_engine as le  # noqa: E402

XLSX = os.path.join(ROOT, "data", "book_job.xlsx")


def srcs(sql):
    return sorted(le.parse_sql(sql).sources)


def test_update_with_subqueries():
    r = le.parse_sql("UPDATE SCD_CON_DTL c SET c.DTL_SNAP_END_DATE = (SELECT MAX(DTL_SNAP_DATE) FROM STG_SCD_CON_S5) "
                     "WHERE c.DTL_SNAP_KEY IN (SELECT x.DTL_SNAP_KEY FROM STG_SCD_CON_S5 x WHERE x.DTL_SNAP_KEY IS NOT NULL)")
    assert r.stmt_type == "UPDATE"
    assert r.targets == ["SCD_CON_DTL"]
    assert sorted(r.sources) == [("STG_SCD_CON_S5", "DATA"), ("STG_SCD_CON_S5", "FILTER")]


def test_delete_filter_context():
    r = le.parse_sql("DELETE FROM SNAP_BKG WHERE BOOKED_MONTH IN (SELECT CURR_BKG_MON FROM LKP_A_PULL_VAR)")
    assert r.targets == ["SNAP_BKG"]
    assert r.sources == [("LKP_A_PULL_VAR", "FILTER")]


def test_delete_without_source():
    r = le.parse_sql("DELETE FROM LKP_M_MON_VAR_OVR")
    assert r.targets == ["LKP_M_MON_VAR_OVR"] and r.sources == []


def test_insert_select_star():
    r = le.parse_sql("INSERT INTO SNAP_BKG SELECT * FROM APP_SNAP_BKG_V")
    assert r.targets == ["SNAP_BKG"] and r.sources == [("APP_SNAP_BKG_V", "DATA")]


def test_self_referencing_insert():
    r = le.parse_sql("INSERT INTO LKP_M_CONTRACT_TYPE SELECT ADD_MONTHS(BKG_MON,1), CONTRACT_TYPE FROM LKP_M_CONTRACT_TYPE "
                     "WHERE BKG_MON = (SELECT MAX(BKG_MON) FROM LKP_M_CONTRACT_TYPE) AND DEL_FLAG IS NULL")
    assert sorted(r.sources) == [("LKP_M_CONTRACT_TYPE", "DATA"), ("LKP_M_CONTRACT_TYPE", "FILTER")]


def test_plsql_call():
    r = le.parse_sql("BEGIN BOOKINGS.SEND_DAILY_LOAD_STATUS_EMAIL; END;")
    assert r.stmt_type == "PLSQL" and r.calls == ["BOOKINGS.SEND_DAILY_LOAD_STATUS_EMAIL"]


def test_cte_joins_and_comments():
    sql = """WITH base AS (SELECT * FROM t1 -- comment FROM fake
             ) SELECT b.x FROM base b JOIN t2 ON t2.id = b.id, t3 x
             WHERE EXISTS (SELECT 1 FROM t4 WHERE t4.k = q'[a FROM b]')"""
    assert srcs(sql) == [("T1", "DATA"), ("T2", "DATA"), ("T3", "DATA"), ("T4", "FILTER")]


def test_merge():
    r = le.parse_sql("MERGE INTO tgt t USING (SELECT k, v FROM src) s ON (t.k = s.k) "
                     "WHEN MATCHED THEN UPDATE SET t.v = s.v WHEN NOT MATCHED THEN INSERT (k, v) VALUES (s.k, s.v)")
    assert r.targets == ["TGT"] and r.sources == [("SRC", "DATA")]


def test_disabled_markers():
    assert le.is_disabled("Y") and le.is_disabled(" y ") and le.is_disabled("Deleted")
    assert not le.is_disabled(None) and not le.is_disabled("N")


@pytest.mark.skipif(not os.path.exists(XLSX), reason="sample workbook not present")
def test_engine_on_book_jobs(tmp_path):
    pytest.importorskip("openpyxl")
    jobs = le.read_jobs(XLSX)
    eng = le.Engine(jobs).run()
    active = [j for j in jobs if j["IS_ACTIVE"] == "Y"]
    assert len(jobs) == 406 and len(active) == 375
    assert sum(j["CASE_TYPE"] == "A_STANDARD" for j in active) == 280
    assert sum(j["CASE_TYPE"] == "B_SQL" for j in active) == 95
    assert not [j for j in active if j["PARSE_STATUS"] == "FALLBACK"]
    # no edge produced by a disabled job
    disabled = {j["JOB_NUM"] for j in jobs if j["IS_ACTIVE"] == "N"}
    assert not [e for e in eng.edges if e["JOB_NUM"] in disabled]
    assert len({g["GROUP_NAME"] for g in eng.groups}) == 27
    assert eng.nodes["STATUS EMAIL"]["NODE_TYPE"] == "PSEUDO"
    assert eng.nodes["CON_DL.SEND_CON_UPDATES"]["NODE_TYPE"] == "PROCEDURE"
    assert eng.nodes["SNAP_BKG"]["NODE_CLASS"] == "TERMINAL"


def test_view_definitions_resolve_skipped_dependency():
    jobs = [
        dict(JOB_NUM=1, JOB_NAMES="ALL|A", TARGET_OBJECT="TABLE_1", SOURCE_OBJECT="SRC_V", UNIQUE_COL=None,
             FILTER_CLAUSE=None, SQL_STMT=None, DISABLED_FLAG=None),
        dict(JOB_NUM=2, JOB_NAMES="ALL|A", TARGET_OBJECT="TABLE_2", SOURCE_OBJECT="OTHER_V", UNIQUE_COL=None,
             FILTER_CLAUSE=None, SQL_STMT=None, DISABLED_FLAG=None),
        dict(JOB_NUM=5, JOB_NAMES="ALL|B", TARGET_OBJECT="TABLE_5", SOURCE_OBJECT="VIEW_E", UNIQUE_COL=None,
             FILTER_CLAUSE=None, SQL_STMT=None, DISABLED_FLAG=None),
        dict(JOB_NUM=6, JOB_NAMES="ALL|B", TARGET_OBJECT="TABLE_6", SOURCE_OBJECT="VIEW_E", UNIQUE_COL=None,
             FILTER_CLAUSE=None, SQL_STMT=None, DISABLED_FLAG="Y"),
    ]
    views = {"VIEW_E": "select a.x from view_d a join table_2 b on b.id = a.id",
             "VIEW_D": "select * from table_1"}
    eng = le.Engine(jobs, views=views).run()
    deps = {(d["JOB_NUM"], d["DEPENDS_ON_JOB"]): d for d in eng.deps}
    assert deps[(5, 1)]["HOPS"] == 2 and deps[(5, 1)]["VIA_OBJECT"] == "TABLE_1"
    assert deps[(5, 2)]["HOPS"] == 1 and deps[(5, 2)]["SAME_GROUP"] == "Y"
    assert eng.nodes["SRC_V"]["NODE_CLASS"] == "ROOT"
    assert eng.nodes["TABLE_5"]["NODE_CLASS"] == "TERMINAL"
    assert eng.nodes["TABLE_1"]["NODE_CLASS"] == "INTERMEDIATE"
    assert "TABLE_6" not in eng.nodes            # disabled job ignored
    assert eng.nodes["TABLE_5"]["DAG_LEVEL"] == 4  # SRC_V -> TABLE_1 -> VIEW_D -> VIEW_E -> TABLE_5


def test_outputs_written(tmp_path):
    pytest.importorskip("openpyxl")
    if not os.path.exists(XLSX):
        pytest.skip("sample workbook not present")
    le.main([XLSX, "--out", str(tmp_path)])
    for f in ("jobs.csv", "edges.csv", "nodes.csv", "job_groups.csv", "job_deps.csv",
              "book_jobs_load.sql", "extract_view_ddl.sql"):
        assert (tmp_path / f).exists(), f
    with open(tmp_path / "edges.csv") as fh:
        assert sum(1 for _ in csv.DictReader(fh)) == 354
