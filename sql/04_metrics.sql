-- =====================================================================
-- 04_metrics.sql  |  GOLDEN -> METRICS
-- golden.metrics_monthly : one row per month. Each KPI appears twice where
-- relevant: the "naive" version (how such numbers are usually reported)
-- and the "challenged" version (our definition). See docs/metric_definitions.md
-- =====================================================================

-- Unit costs are NOT in the data. These are placeholders so that the
-- cost-per-rupee metric has a shape; replace with finance figures.
CREATE OR REPLACE TABLE golden.assumed_unit_costs AS
SELECT * FROM (VALUES
  ('agent_hour',      250.0, 'INR per logged-in agent hour (salary + overhead)'),
  ('call',              1.5, 'INR telephony cost per dial'),
  ('whatsapp_message',  0.8, 'INR per WhatsApp message event'),
  ('sms',               0.15,'INR per SMS'),
  ('field_visit',     300.0, 'INR per field visit')
) t(cost_item, inr_per_unit, note);

CREATE OR REPLACE TABLE golden.metrics_monthly AS
WITH book AS (SELECT SUM(outstanding_amount) AS book_outstanding, COUNT(*) AS n_accounts FROM golden.dim_account),
raw_pay AS (   -- what a report built straight on the raw table would say
  SELECT DATE_TRUNC('month', event_at)::DATE AS month_start,
         SUM(amount) FILTER (payment_status = 'SUCCESS') AS naive_recovery_raw_rows,
         SUM(amount)                                     AS naive_recovery_all_statuses
  FROM stg.payments GROUP BY 1),
pay AS (
  SELECT paid_month AS month_start,
         SUM(amount) FILTER (is_recovery)                          AS recovery_amount,
         COUNT(*)   FILTER (is_recovery)                          AS n_payments,
         COUNT(DISTINCT account_id) FILTER (is_recovery)          AS n_paying_accounts,
         SUM(amount) FILTER (is_recovery AND reference_use_seq=1) AS recovery_if_reused_refs_removed,
         SUM(amount) FILTER (payment_status = 'REVERSED')         AS reversed_amount,
         SUM(amount) FILTER (payment_status = 'PENDING')          AS pending_amount
  FROM golden.fact_payment GROUP BY 1),
am AS (
  SELECT month_start,
         COUNT(*) FILTER (n_calls > 0)                  AS accounts_dialled,
         COUNT(*) FILTER (n_calls_answered > 0)         AS accounts_answered,
         COUNT(*) FILTER (n_rpc > 0)                    AS accounts_rpc,
         COUNT(*) FILTER (n_touches > 0)                AS accounts_worked,
         COUNT(*) FILTER (n_effective_contacts > 0)     AS accounts_contacted,
         COUNT(*) FILTER (n_ptp > 0)                    AS accounts_with_ptp,
         COUNT(*) FILTER (n_ptp > 0 AND n_effective_contacts > 0) AS accounts_contacted_with_ptp,
         SUM(recovered_amount) FILTER (n_touches > 0)   AS recovery_from_worked_accounts,
         COUNT(*) FILTER (n_target_rows > 0)            AS accounts_targeted,
         SUM(n_calls) AS n_calls, SUM(n_whatsapp) AS n_whatsapp, SUM(n_sms) AS n_sms, SUM(n_visits) AS n_visits
  FROM golden.fact_account_month GROUP BY 1),
calls AS (
  SELECT call_month AS month_start,
         AVG(is_answered::INT)                          AS naive_contact_rate_calls,
         COUNT(*) FILTER (has_disposition)              AS dispositioned_calls,
         AVG((final_disposition NOT IN ('NO_CONTACT','WRONG_NUMBER'))::INT) FILTER (has_disposition) AS naive_rpc_rate_dispositions
  FROM golden.fact_call GROUP BY 1),
ptp AS (
  SELECT ptp_month AS month_start, COUNT(*) AS n_ptp,
         COUNT(*) FILTER (reported_status='KEPT') * 1.0
           / NULLIF(COUNT(*) FILTER (reported_status IN ('KEPT','BROKEN')), 0) AS naive_ptp_kept_rate,
         COUNT(*) FILTER (is_matured)                                         AS n_ptp_matured,
         AVG(verified_kept::INT)        FILTER (is_matured)                   AS verified_ptp_kept_rate,
         AVG(verified_any_payment::INT) FILTER (is_matured)                   AS verified_ptp_any_payment_rate
  FROM golden.fact_ptp GROUP BY 1),
ses AS (SELECT session_month AS month_start, SUM(session_seconds)/3600.0 AS agent_hours,
               COUNT(DISTINCT agent_id) AS active_agents
        FROM clean.agent_sessions GROUP BY 1),
cost AS (SELECT MAX(inr_per_unit) FILTER (cost_item='agent_hour') ah, MAX(inr_per_unit) FILTER (cost_item='call') cl,
                MAX(inr_per_unit) FILTER (cost_item='whatsapp_message') wa, MAX(inr_per_unit) FILTER (cost_item='sms') sm,
                MAX(inr_per_unit) FILTER (cost_item='field_visit') fv FROM golden.assumed_unit_costs)
SELECT
  m.month_label, m.month_start, m.days_observed, m.is_full_month,
  -- ---- recovery: naive vs clean ----
  r.naive_recovery_all_statuses, r.naive_recovery_raw_rows,
  p.recovery_amount, p.recovery_if_reused_refs_removed, p.reversed_amount, p.pending_amount,
  p.recovery_amount / m.days_observed                    AS recovery_per_day,
  p.n_payments, p.n_paying_accounts,
  p.recovery_amount / p.n_payments                       AS avg_ticket,
  -- ---- rates ----
  p.recovery_amount / b.book_outstanding                 AS recovery_rate_of_book,
  p.recovery_amount / m.days_observed * 30 / b.book_outstanding AS recovery_rate_of_book_30d,
  p.n_paying_accounts * 1.0 / b.n_accounts               AS payer_rate,
  p.recovery_amount / b.n_accounts                       AS recovery_per_account_in_book,
  am.recovery_from_worked_accounts / am.accounts_worked  AS recovery_per_worked_account,
  -- ---- funnel ----
  am.accounts_targeted, am.accounts_worked, am.accounts_dialled, am.accounts_answered, am.accounts_rpc,
  c.naive_contact_rate_calls,
  am.accounts_answered * 1.0 / am.accounts_dialled       AS contact_rate_accounts,
  c.naive_rpc_rate_dispositions,
  am.accounts_rpc * 1.0 / am.accounts_dialled            AS rpc_rate_accounts,
  t.n_ptp,
  am.accounts_contacted_with_ptp * 1.0 / am.accounts_contacted AS ptp_rate_of_contacted_accounts,
  t.naive_ptp_kept_rate, t.verified_ptp_kept_rate, t.verified_ptp_any_payment_rate,
  -- ---- productivity & cost ----
  s.agent_hours, s.active_agents,
  p.recovery_amount / s.agent_hours                      AS recovery_per_agent_hour,
  (s.agent_hours*cost.ah + am.n_calls*cost.cl + am.n_whatsapp*cost.wa + am.n_sms*cost.sm + am.n_visits*cost.fv) AS assumed_cost,
  (s.agent_hours*cost.ah + am.n_calls*cost.cl + am.n_whatsapp*cost.wa + am.n_sms*cost.sm + am.n_visits*cost.fv)
     / p.recovery_amount                                 AS assumed_cost_per_rupee_recovered
FROM golden.dim_month m
CROSS JOIN book b CROSS JOIN cost
LEFT JOIN raw_pay r USING (month_start) LEFT JOIN pay p USING (month_start)
LEFT JOIN am USING (month_start) LEFT JOIN calls c USING (month_start)
LEFT JOIN ptp t USING (month_start) LEFT JOIN ses s USING (month_start)
ORDER BY m.month_start;

-- Daily recovery series (for trend / change-point tests and the dashboard)
CREATE OR REPLACE TABLE golden.metrics_daily AS
SELECT d::DATE AS day,
       COALESCE(SUM(p.amount) FILTER (p.is_recovery), 0) AS recovery_amount,
       COUNT(*) FILTER (p.is_recovery)                   AS n_payments
FROM generate_series(DATE '2026-01-01', DATE '2026-08-08', INTERVAL 1 DAY) t(d)
LEFT JOIN golden.fact_payment p ON p.paid_date = d::DATE
GROUP BY 1 ORDER BY 1;
