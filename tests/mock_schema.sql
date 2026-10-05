--------------------------------------------------------------------------------
-- tests/mock_schema.sql
-- A miniature version of the Book_Jobs objects (tables + layered views) used to
-- exercise view capture, column lineage, cycles and view-skipping dependencies.
-- Object names match BOOK_JOBS rows so the real metadata drives the test.
--------------------------------------------------------------------------------
set define off

begin
  for o in (select object_name, object_type from user_objects
            where object_type in ('VIEW', 'TABLE')
            and object_name in ('SRC_CONTRACT_HDR','SRC_CONTRACT_DTL','SRC_FX_RATE','SRC_ACCOUNT',
                                'LKP_M_MON_VAR','LKP_A_PULL_VAR','STG_SCD_CON_S5','SCD_CON_DTL','SNAP_BKG',
                                'LKP_M_MON_VAR_OVR','APP_LKP_M_MON_VAR_V','LKP_A_PULL_VAR_V',
                                'STG_SCD_CON_S5_V','APP_SCD_CON_DTL_V','APP_SNAP_BKG_V','BKG_BASE_V',
                                'RPT_DAILY_LIST_1C_V','RPT_DAILY_LIST_1C'))
  loop
    execute immediate 'drop ' || o.object_type || ' ' || o.object_name ||
                      case o.object_type when 'TABLE' then ' cascade constraints purge' end;
  end loop;
end;
/

-- external / base tables (true roots)
create table src_contract_hdr (con_id number, account_id number, status varchar2(10), currency_code varchar2(3), signed_date date);
create table src_contract_dtl (con_id number, line_id number, prod_id varchar2(20), amt number, start_date date, end_date date);
create table src_fx_rate      (currency_code varchar2(3), bkg_mon date, rate number);
create table src_account      (account_id number, account_name varchar2(100), region varchar2(20));

-- month variables
create table lkp_m_mon_var (bkg_mon date, curr_mon_flg varchar2(1), pull_date date);
create table lkp_m_mon_var_ovr (bkg_mon date);
create or replace view app_lkp_m_mon_var_v as
select trunc(sysdate, 'MM') bkg_mon, 'Y' curr_mon_flg, sysdate pull_date from dual;

create or replace view lkp_a_pull_var_v as
select max(bkg_mon) curr_bkg_mon, max(pull_date) pull_date
from   lkp_m_mon_var
where  curr_mon_flg = 'Y';
create table lkp_a_pull_var as select * from lkp_a_pull_var_v where 1 = 0;

-- SCD contract detail (target) -- created first so the staging view can read it
create table scd_con_dtl (
  dtl_snap_key       varchar2(100),
  con_id             number,
  line_id            number,
  prod_id            varchar2(20),
  amt_usd            number,
  bkg_mon            date,
  dtl_snap_date      date,
  dtl_snap_start_date date,
  dtl_snap_end_date  date);

-- staging view: joins source with the current SCD rows (=> cycle SCD_CON_DTL -> view -> STG -> SCD_CON_DTL)
create or replace view stg_scd_con_s5_v as
with cur as (
  select dtl_snap_key, con_id, line_id, amt_usd
  from   scd_con_dtl
  where  dtl_snap_end_date is null
)
select d.con_id || '-' || d.line_id || '-' || to_char(p.curr_bkg_mon, 'YYYYMM') as dtl_snap_key,
       d.con_id,
       d.line_id,
       d.prod_id,
       round(d.amt * nvl(fx.rate, 1), 2)                              as amt_usd,
       p.curr_bkg_mon                                                 as bkg_mon,
       trunc(sysdate)                                                 as dtl_snap_date,
       case when cur.dtl_snap_key is null then 'NEW'
            when cur.amt_usd != round(d.amt * nvl(fx.rate, 1), 2) then 'CHANGED'
            else 'SAME' end                                           as change_type
from   src_contract_dtl d
join   src_contract_hdr h on h.con_id = d.con_id and h.status <> 'CANCELLED'
left   join src_fx_rate fx on fx.currency_code = h.currency_code and fx.bkg_mon = trunc(d.start_date, 'MM')
cross  join lkp_a_pull_var p
left   join cur on cur.con_id = d.con_id and cur.line_id = d.line_id;

create table stg_scd_con_s5 as select * from stg_scd_con_s5_v where 1 = 0;

create or replace view app_scd_con_dtl_v as
select s.dtl_snap_key, s.con_id, s.line_id, s.prod_id, s.amt_usd, s.bkg_mon,
       s.dtl_snap_date, s.dtl_snap_date dtl_snap_start_date, cast(null as date) dtl_snap_end_date
from   stg_scd_con_s5 s
where  s.change_type in ('NEW', 'CHANGED');

-- bookings snapshot: CTE + inline view + aggregate + analytic + scalar subquery
create or replace view bkg_base_v as
select c.con_id, c.prod_id, c.amt_usd, c.bkg_mon, h.account_id
from   scd_con_dtl c
join   src_contract_hdr h on h.con_id = c.con_id
where  c.dtl_snap_end_date is null;

create or replace view app_snap_bkg_v as
with acct as (
  select account_id, account_name, upper(region) region from src_account
)
select b.bkg_mon                                         as booked_month,
       b.account_id,
       a.account_name,
       a.region,
       sum(b.amt_usd)                                    as tcv_usd,
       count(distinct b.con_id)                          as con_cnt,
       rank() over (partition by b.bkg_mon order by sum(b.amt_usd) desc) as acct_rank,
       (select max(x.pull_date) from lkp_a_pull_var x)   as snap_pull_date
from   bkg_base_v b
join   acct a on a.account_id = b.account_id
group  by b.bkg_mon, b.account_id, a.account_name, a.region;

create table snap_bkg as select * from app_snap_bkg_v where 1 = 0;

-- a report view reading the snapshot table two layers further down
create or replace view rpt_daily_list_1c_v as
select s.booked_month, s.account_name, s.tcv_usd,
       decode(s.acct_rank, 1, 'TOP', 'OTHER') rank_band
from   snap_bkg s
union all
select p.curr_bkg_mon, 'TOTAL', null, 'N/A' from lkp_a_pull_var p;

create table rpt_daily_list_1c as select * from rpt_daily_list_1c_v where 1 = 0;
