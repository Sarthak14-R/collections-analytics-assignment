-- =====================================================================
-- 06_analysis.sql  |  Parts 3 & 4 - drivers, bias checks, counterfactual
-- Named queries, same convention as 05_forensics.sql.
-- ${DIM} is replaced by a column / expression by src/sqlq.py
-- =====================================================================

-- name: T1_month_on_month
-- The headline. Total recovery vs recovery PER DAY (months have 28-31 days).
SELECT month_label, days_observed,
       ROUND(naive_recovery_raw_rows/1e7,2) AS reported_style_cr,
       ROUND(100*(naive_recovery_raw_rows/LAG(naive_recovery_raw_rows) OVER w - 1),1) AS reported_style_mom_pct,
       ROUND(recovery_amount/1e7,2) AS clean_cr,
       ROUND(100*(recovery_amount/LAG(recovery_amount) OVER w - 1),1) AS clean_mom_pct,
       ROUND(recovery_per_day/1e5,2) AS clean_per_day_lakh,
       ROUND(100*(recovery_per_day/LAG(recovery_per_day) OVER w - 1),1) AS per_day_mom_pct,
       ROUND(100*(days_observed*1.0/LAG(days_observed) OVER w - 1),1) AS calendar_days_mom_pct
FROM golden.metrics_monthly WHERE is_full_month
WINDOW w AS (ORDER BY month_start) ORDER BY month_start;

-- name: setup_call_outcomes
-- Outcome per call: did the account make a successful payment in the 7 days AFTER the call?
CREATE OR REPLACE TEMP TABLE an_call AS
SELECT c.call_id, c.account_id, c.call_at_ist, c.call_month, c.call_hour_ist, c.agent_id, c.vendor_id,
       c.direction, c.is_answered, c.is_rpc, c.n_attempt_rows, c.campaign_id, c.campaign_name,
       c.strategy_version, c.campaign_channel,
       v.vendor_name, v.status AS vendor_status,
       g.team AS agent_team,
       CASE WHEN g.tenure_months_at_start IS NULL THEN 'unknown'
            WHEN g.tenure_months_at_start < 6  THEN '0-5m'
            WHEN g.tenure_months_at_start < 12 THEN '6-11m'
            WHEN g.tenure_months_at_start < 18 THEN '12-17m' ELSE '18m+' END AS agent_tenure_band,
       CASE WHEN c.call_hour_ist < 8 THEN '00-07' WHEN c.call_hour_ist < 12 THEN '08-11'
            WHEN c.call_hour_ist < 16 THEN '12-15' WHEN c.call_hour_ist < 19 THEN '16-18' ELSE '19-23' END AS hour_band_ist,
       EXISTS (SELECT 1 FROM golden.fact_payment p
               WHERE p.account_id = c.account_id AND p.is_recovery
                 AND p.paid_at_ist > c.call_at_ist AND p.paid_at_ist <= c.call_at_ist + INTERVAL 7 DAY) AS paid_within_7d
FROM golden.fact_call c
LEFT JOIN clean.vendor_telephony v USING (vendor_id)
LEFT JOIN golden.dim_agent g USING (agent_id)
WHERE c.call_date <= DATE '2026-08-01';      -- leave 7 full days of follow-up

-- name: D_call_dimension
-- Call-level driver cut. Outcomes: answered rate, and payment within 7 days of the call.
SELECT CAST(${DIM} AS VARCHAR) AS level, COUNT(*) AS calls,
       SUM(is_answered::INT) AS answered, SUM(paid_within_7d::INT) AS paid_7d,
       ROUND(100.0*AVG(is_answered::INT),2) AS answered_pct,
       ROUND(100.0*AVG(paid_within_7d::INT),2) AS paid_7d_pct
FROM an_call GROUP BY 1 ORDER BY 1;

-- name: D_account_dimension
-- Account-level driver cut on full months. Outcome: paid in the month (account-months).
SELECT CAST(${DIM} AS VARCHAR) AS level, COUNT(*) AS account_months, SUM(m.paid_flag::INT) AS paying,
       ROUND(100.0*AVG(m.paid_flag::INT),2) AS payer_rate_pct,
       ROUND(SUM(m.recovered_amount)/COUNT(*)) AS recovery_per_account_month
FROM golden.fact_account_month m JOIN golden.dim_account a USING (account_id)
WHERE m.month_start < DATE '2026-08-01' GROUP BY 1 ORDER BY 1;

-- name: D_account_dimension_by_month
SELECT STRFTIME(m.month_start,'%Y-%m') AS month_label, CAST(${DIM} AS VARCHAR) AS level,
       COUNT(*) AS accounts, SUM(m.paid_flag::INT) AS paying, SUM(m.recovered_amount) AS recovered,
       COUNT(*) FILTER (m.n_touches > 0) AS worked
FROM golden.fact_account_month m JOIN golden.dim_account a USING (account_id)
WHERE m.month_start < DATE '2026-08-01' GROUP BY 1,2 ORDER BY 1,2;

-- name: CH_channel_conversion
-- Channel conversion = % of effective contacts followed by a successful payment within 7 days.
-- It only means something next to the BASELINE: the chance that any account pays in any 7-day window.
WITH t AS (
  SELECT t.channel, t.touch_id,
         EXISTS (SELECT 1 FROM golden.fact_payment p WHERE p.account_id = t.account_id AND p.is_recovery
                   AND p.paid_at_ist > t.touch_at AND p.paid_at_ist <= t.touch_at + INTERVAL 7 DAY) AS paid_7d
  FROM golden.fact_touch t WHERE t.is_effective_contact AND t.touch_at < TIMESTAMP '2026-08-01'),
weeks AS (SELECT w::DATE AS wk FROM generate_series(DATE '2026-01-01', DATE '2026-07-30', INTERVAL 7 DAY) x(w)),
base AS (
  SELECT 'BASELINE (any account, any week)' AS channel,
         (SELECT COUNT(*) FROM golden.dim_account) * (SELECT COUNT(*) FROM weeks) AS n,
         (SELECT COUNT(*) FROM (SELECT DISTINCT p.account_id, w.wk FROM golden.fact_payment p JOIN weeks w
              ON p.is_recovery AND p.paid_date >= w.wk AND p.paid_date < w.wk + 7)) AS paid)
SELECT channel, COUNT(*) AS n, SUM(paid_7d::INT) AS paid FROM t GROUP BY 1
UNION ALL SELECT * FROM base ORDER BY 1;

-- name: AF_attempt_frequency
-- Account-month: how many times we dialled vs whether they paid that month.
SELECT CASE WHEN n_calls >= 4 THEN '4+' ELSE CAST(n_calls AS VARCHAR) END AS calls_in_month,
       COUNT(*) AS account_months, SUM(paid_flag::INT) AS paying,
       ROUND(100.0*AVG(paid_flag::INT),2) AS payer_rate_pct
FROM golden.fact_account_month WHERE month_start < DATE '2026-08-01' GROUP BY 1 ORDER BY 1;

-- name: SEL_selection_bias
-- Are the accounts we choose to target/contact different BEFORE we touch them?
SELECT CASE WHEN m.n_target_rows > 0 THEN 'targeted' ELSE 'not targeted' END AS grp,
       COUNT(*) AS account_months, ROUND(AVG(a.dpd),2) AS avg_dpd,
       ROUND(100.0*AVG((a.risk_segment IN ('HIGH','NPA'))::INT),2) AS pct_high_npa,
       ROUND(AVG(a.outstanding_amount)) AS avg_outstanding,
       SUM(m.paid_flag::INT) AS paying, ROUND(100.0*AVG(m.paid_flag::INT),2) AS payer_rate_pct
FROM golden.fact_account_month m JOIN golden.dim_account a USING (account_id)
WHERE m.month_start < DATE '2026-08-01' GROUP BY 1 ORDER BY 1;

-- name: COH_vintage_cohorts
SELECT STRFTIME(a.opened_at,'%Y') || '-H' || CASE WHEN MONTH(a.opened_at)<=6 THEN '1' ELSE '2' END AS vintage,
       STRFTIME(m.month_start,'%Y-%m') AS month_label,
       ROUND(100.0*AVG(m.paid_flag::INT),2) AS payer_rate_pct
FROM golden.fact_account_month m JOIN golden.dim_account a USING (account_id)
WHERE m.month_start < DATE '2026-08-01' GROUP BY 1,2 ORDER BY 1,2;

-- name: SURV_survivorship
-- Survivorship test: recompute the payer rate each month using only accounts that had
-- NOT yet paid earlier in the year ("still unresolved"), next to the full-book rate.
WITH x AS (
  SELECT m.*, SUM(m.n_payments) OVER (PARTITION BY account_id ORDER BY month_start
                                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_payments
  FROM golden.fact_account_month m WHERE month_start < DATE '2026-08-01')
SELECT STRFTIME(month_start,'%Y-%m') AS month_label,
       ROUND(100.0*AVG(paid_flag::INT),2) AS payer_rate_full_book_pct,
       COUNT(*) FILTER (COALESCE(prior_payments,0)=0) AS never_paid_before,
       ROUND(100.0*AVG(paid_flag::INT) FILTER (COALESCE(prior_payments,0)=0),2) AS payer_rate_never_paid_before_pct,
       ROUND(100.0*AVG(paid_flag::INT) FILTER (prior_payments>0),2) AS payer_rate_paid_before_pct
FROM x GROUP BY 1 ORDER BY 1;

-- name: CF_targeting_rows
-- Counterfactual input: one row per targeting decision with a 30-day payment outcome.
--   arm    : NEW = campaign strategy v2/v3, OLD = legacy/v1
--   period : PRE / POST the assumed cut-over date ${CUTOVER}
SELECT t.target_id, t.account_id, t.target_date,
       CASE WHEN k.is_new_strategy THEN 'NEW' ELSE 'OLD' END AS arm,
       CASE WHEN t.target_date >= DATE '${CUTOVER}' THEN 'POST' ELSE 'PRE' END AS period,
       a.dpd_bucket, a.risk_segment, a.loan_type, a.outstanding_amount,
       EXISTS (SELECT 1 FROM golden.fact_payment p WHERE p.account_id = t.account_id AND p.is_recovery
                 AND p.paid_date > t.target_date AND p.paid_date <= t.target_date + 30) AS paid_30d,
       COALESCE((SELECT SUM(p.amount) FROM golden.fact_payment p WHERE p.account_id = t.account_id AND p.is_recovery
                 AND p.paid_date > t.target_date AND p.paid_date <= t.target_date + 30), 0) AS amount_30d
FROM clean.daily_targeting t JOIN clean.campaigns k USING (campaign_id) JOIN golden.dim_account a USING (account_id)
WHERE t.target_date <= DATE '2026-07-09';
