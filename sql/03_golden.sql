-- =====================================================================
-- 03_golden.sql  |  CLEAN -> GOLDEN
-- The golden layer is what analysts and dashboards are allowed to read.
-- Grain of each table is stated in its header. Reporting window:
--   2026-01-01 .. 2026-08-08 (IST). August is a PARTIAL month (8 days).
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS golden;

-- ---------- dim_month : calendar, so every metric can be per-day ----------
CREATE OR REPLACE TABLE golden.dim_month AS
SELECT m::DATE AS month_start,
       STRFTIME(m, '%Y-%m') AS month_label,
       CASE WHEN m = DATE '2026-08-01' THEN 8 ELSE DAY(LAST_DAY(m)) END AS days_observed,
       (m < DATE '2026-08-01') AS is_full_month
FROM generate_series(DATE '2026-01-01', DATE '2026-08-01', INTERVAL 1 MONTH) t(m);

-- ---------- dim_account : one row per account ----------
-- Source of truth for account -> borrower is clean.accounts, NOT the
-- borrower_id written on event rows (they disagree ~100% of the time).
CREATE OR REPLACE TABLE golden.dim_account AS
SELECT a.account_id, a.borrower_id, a.is_borrower_missing,
       a.loan_type, a.principal_amount, a.outstanding_amount, a.dpd, a.dpd_bucket,
       a.risk_segment, a.snapshot_status, a.opened_at, a.schema_version,
       COALESCE(b.city,  'UNKNOWN') AS city,
       COALESCE(b.state, 'UNKNOWN') AS state,
       COALESCE(b.n_cities, 0)      AS borrower_n_cities    -- >1 => geography is low-trust
FROM clean.accounts a
LEFT JOIN clean.borrowers b USING (borrower_id);

-- ---------- dim_agent : one row per agent_id ----------
CREATE OR REPLACE TABLE golden.dim_agent AS
SELECT agent_id, team, vendor_id, status, joined_at, earliest_joined_at,
       n_versions, n_employee_codes,
       DATE_DIFF('month', joined_at, DATE '2026-01-01') AS tenure_months_at_start
FROM clean.agents;

-- ---------- fact_call : one row per real call ----------
CREATE OR REPLACE TABLE golden.fact_call AS
WITH fd AS (SELECT call_id, disposition_code, contact_class
            FROM clean.call_dispositions WHERE is_final_for_call),
att AS (SELECT call_id, COUNT(*) AS n_attempt_rows, MAX(attempt_no) AS max_attempt_no
        FROM clean.call_attempts GROUP BY 1)
SELECT c.*,
       fd.disposition_code AS final_disposition,
       (fd.call_id IS NOT NULL) AS has_disposition,
       -- RPC = the call was ANSWERED *and* the final disposition says we spoke to the borrower.
       -- A "PTP" disposition on a call that was never answered is not counted.
       (c.is_answered AND fd.contact_class = 'RPC') IS TRUE AS is_rpc,
       (fd.contact_class = 'RPC' AND NOT c.is_answered) IS TRUE AS is_rpc_on_unanswered_call,
       COALESCE(att.n_attempt_rows, 0) AS n_attempt_rows,
       k.campaign_name, k.strategy_version, k.channel AS campaign_channel,
       (c.call_at_ist BETWEEN k.start_at AND k.end_at) AS is_inside_campaign_window
FROM clean.calls c
LEFT JOIN fd  USING (call_id)
LEFT JOIN att USING (call_id)
LEFT JOIN clean.campaigns k USING (campaign_id)
WHERE c.call_date BETWEEN DATE '2026-01-01' AND DATE '2026-08-08';   -- exclusion rule E1

-- ---------- fact_touch : one row per borrower touch, all channels ----------
-- is_effective_contact = the borrower demonstrably received/engaged, per channel:
--   VOICE    answered call
--   WHATSAPP READ / REPLIED / PAYMENT_CLICK   (SENT/DELIVERED is not contact)
--   SMS      DELIVERED / CLICKED              (no read receipt exists for SMS)
--   FIELD    outcome CONTACTED / PTP / PAID / REFUSED (someone was met)
CREATE OR REPLACE TABLE golden.fact_touch AS
SELECT call_id AS touch_id, account_id, call_at_ist AS touch_at, 'VOICE' AS channel,
       is_answered AS is_effective_contact, campaign_id, agent_id
FROM golden.fact_call
UNION ALL
SELECT whatsapp_event_id, account_id, event_at_ist, 'WHATSAPP',
       event_type IN ('READ','REPLIED','PAYMENT_CLICK'), NULL, NULL
FROM clean.whatsapp_events
UNION ALL
SELECT sms_event_id, account_id, event_at_ist, 'SMS',
       event_type IN ('DELIVERED','CLICKED'), NULL, NULL
FROM clean.sms_events
UNION ALL
SELECT visit_id, account_id, visit_at_ist, 'FIELD',
       outcome IN ('CONTACTED','PTP','PAID','REFUSED'), NULL, agent_id
FROM clean.field_visits;

-- ---------- fact_payment : one row per real payment event ----------
-- is_recovery is THE definition of recovered money: a unique, SUCCESSFUL payment.
-- Attribution columns:
--   last_touch_*  : latest effective contact in the 7 days BEFORE the payment
--   naive_latest_campaign : what a "latest campaign ever" rule would credit
CREATE OR REPLACE TABLE golden.fact_payment AS
WITH lt AS (
  SELECT p.payment_id,
         ARG_MAX(t.channel, t.touch_at)       AS last_touch_channel_7d,
         COUNT(DISTINCT t.channel)            AS n_channels_7d,
         COUNT(*)                             AS n_touches_7d
  FROM clean.payments p
  JOIN golden.fact_touch t
    ON t.account_id = p.account_id AND t.is_effective_contact
   AND t.touch_at <  p.paid_at_ist
   AND t.touch_at >= p.paid_at_ist - INTERVAL 7 DAY
  GROUP BY 1
), nc AS (
  SELECT p.payment_id, ARG_MAX(c.campaign_id, c.call_at_ist) AS naive_latest_campaign
  FROM clean.payments p JOIN golden.fact_call c
    ON c.account_id = p.account_id AND c.call_at_ist < p.paid_at_ist
  GROUP BY 1
)
SELECT p.payment_id, p.account_id, p.paid_at_ist, p.paid_date, p.paid_month,
       p.amount, p.payment_status, p.payment_method, p.provider_id, p.payment_reference,
       p.is_success AS is_recovery,
       p.had_duplicate_row, p.is_reference_missing, p.is_reference_reused, p.reference_use_seq,
       COALESCE(lt.last_touch_channel_7d, 'NO_CONTACT_7D') AS last_touch_channel_7d,
       COALESCE(lt.n_channels_7d, 0) AS n_channels_7d,
       nc.naive_latest_campaign,
       a.loan_type, a.dpd_bucket, a.risk_segment, a.city, a.state
FROM clean.payments p
LEFT JOIN lt USING (payment_id)
LEFT JOIN nc USING (payment_id)
LEFT JOIN golden.dim_account a USING (account_id);

-- ---------- fact_ptp : one row per promise, verified against payments ----------
-- reported_status comes from the source system. verified_kept is OUR test:
-- did successful payments on that account, between the promise and
-- promised_date + 3 days grace, add up to >= 90% of the promised amount?
CREATE OR REPLACE TABLE golden.fact_ptp AS
WITH paid AS (
  SELECT t.ptp_id, SUM(p.amount) AS paid_in_window, COUNT(*) AS n_payments_in_window
  FROM clean.promises_to_pay t
  JOIN clean.payments p
    ON p.account_id = t.account_id AND p.is_success
   AND p.paid_at_ist >= t.promised_at_ist
   AND p.paid_at_ist <= t.promised_date + INTERVAL 3 DAY
  GROUP BY 1
)
SELECT t.*, DATE_TRUNC('month', t.promised_at_ist)::DATE AS ptp_month,
       COALESCE(paid.paid_in_window, 0) AS paid_in_window,
       (t.promised_date + INTERVAL 3 DAY <= TIMESTAMP '2026-08-08 23:59:59') AS is_matured,
       (COALESCE(paid.paid_in_window, 0) >= 0.9 * t.promised_amount) AS verified_kept,
       (COALESCE(paid.paid_in_window, 0) > 0)                        AS verified_any_payment
FROM clean.promises_to_pay t LEFT JOIN paid USING (ptp_id);

-- ---------- fact_account_month : account x month (the analytical workhorse) ----------
-- Every account appears in every month, whether or not anything happened.
-- This is deliberate: it stops "unsuccessful accounts disappearing" (check G).
CREATE OR REPLACE TABLE golden.fact_account_month AS
WITH grid AS (SELECT a.account_id, m.month_start FROM golden.dim_account a CROSS JOIN golden.dim_month m),
tch AS (
  SELECT account_id, DATE_TRUNC('month', touch_at)::DATE AS month_start,
         COUNT(*) FILTER (channel='VOICE')                             AS n_calls,
         COUNT(*) FILTER (channel='VOICE' AND is_effective_contact)    AS n_calls_answered,
         COUNT(*) FILTER (channel='WHATSAPP')                          AS n_whatsapp,
         COUNT(*) FILTER (channel='SMS')                               AS n_sms,
         COUNT(*) FILTER (channel='FIELD')                             AS n_visits,
         COUNT(*)                                                      AS n_touches,
         COUNT(*) FILTER (is_effective_contact)                        AS n_effective_contacts,
         COUNT(DISTINCT channel)                                       AS n_channels
  FROM golden.fact_touch GROUP BY 1,2),
rpc AS (SELECT account_id, call_month AS month_start, COUNT(*) FILTER (is_rpc) AS n_rpc
        FROM golden.fact_call GROUP BY 1,2),
pay AS (SELECT account_id, paid_month AS month_start,
               SUM(amount) FILTER (is_recovery) AS recovered_amount,
               COUNT(*)   FILTER (is_recovery) AS n_payments
        FROM golden.fact_payment GROUP BY 1,2),
ptp AS (SELECT account_id, ptp_month AS month_start, COUNT(*) AS n_ptp FROM golden.fact_ptp GROUP BY 1,2),
tgt AS (SELECT t.account_id, t.target_month AS month_start, COUNT(*) AS n_target_rows,
               COUNT(*) FILTER (t.status='CONTACTED') AS n_target_contacted,
               BOOL_OR(k.is_new_strategy) AS targeted_by_new_strategy
        FROM clean.daily_targeting t JOIN clean.campaigns k USING (campaign_id) GROUP BY 1,2)
SELECT g.account_id, g.month_start,
       COALESCE(n_calls,0) n_calls, COALESCE(n_calls_answered,0) n_calls_answered, COALESCE(n_rpc,0) n_rpc,
       COALESCE(n_whatsapp,0) n_whatsapp, COALESCE(n_sms,0) n_sms, COALESCE(n_visits,0) n_visits,
       COALESCE(n_touches,0) n_touches, COALESCE(n_effective_contacts,0) n_effective_contacts,
       COALESCE(n_channels,0) n_channels, COALESCE(n_ptp,0) n_ptp,
       COALESCE(n_target_rows,0) n_target_rows, COALESCE(n_target_contacted,0) n_target_contacted,
       COALESCE(targeted_by_new_strategy, FALSE) targeted_by_new_strategy,
       COALESCE(recovered_amount,0) recovered_amount, COALESCE(n_payments,0) n_payments,
       (COALESCE(n_payments,0) > 0) AS paid_flag
FROM grid g
LEFT JOIN tch USING (account_id, month_start) LEFT JOIN rpc USING (account_id, month_start)
LEFT JOIN pay USING (account_id, month_start) LEFT JOIN ptp USING (account_id, month_start)
LEFT JOIN tgt USING (account_id, month_start);

-- ---------- audit_cleaning : Raw -> Rejected / Corrected -> Golden ----------
CREATE OR REPLACE TABLE golden.audit_cleaning AS
SELECT * FROM (VALUES
 ('payments', (SELECT COUNT(*) FROM stg.payments),
   (SELECT COUNT(*) FROM stg.payments) - (SELECT COUNT(*) FROM clean.payments),
   (SELECT COUNT(*) FROM clean.payments WHERE is_reference_reused OR is_reference_missing),
   (SELECT COUNT(*) FROM golden.fact_payment),
   'Rejected: duplicate rows per payment_id. Flagged: reused / missing reference. Only SUCCESS rows count as recovery (is_recovery).'),
 ('calls', (SELECT COUNT(*) FROM stg.calls),
   (SELECT COUNT(*) FROM stg.calls) - (SELECT COUNT(*) FROM golden.fact_call),
   (SELECT COUNT(*) FROM golden.fact_call WHERE source_timezone <> 'Asia/Kolkata' OR is_agent_missing OR had_conflicting_timestamp),
   (SELECT COUNT(*) FROM golden.fact_call),
   'Rejected: duplicate call_id rows + calls outside window. Corrected: timezone to IST, missing agent, conflicting timestamp.'),
 ('call_dispositions', (SELECT COUNT(*) FROM stg.call_dispositions), 0,
   (SELECT COUNT(*) FROM clean.call_dispositions WHERE disposition_code_raw = 'PROMISE_TO_PAY'),
   (SELECT COUNT(*) FROM clean.call_dispositions),
   'Corrected: PROMISE_TO_PAY mapped to PTP. All rows kept; latest per call flagged final.'),
 ('call_attempts', (SELECT COUNT(*) FROM stg.call_attempts), 0,
   (SELECT COUNT(*) FROM clean.call_attempts WHERE is_vendor_missing),
   (SELECT COUNT(*) FROM clean.call_attempts), 'Flagged: missing vendor_id.'),
 ('agents', (SELECT COUNT(*) FROM stg.agents),
   (SELECT COUNT(*) FROM stg.agents) - (SELECT COUNT(*) FROM clean.agents), 0,
   (SELECT COUNT(*) FROM golden.dim_agent), 'Rejected: superseded versions; latest updated_at kept per agent_id.'),
 ('borrowers', (SELECT COUNT(*) FROM stg.borrowers),
   (SELECT COUNT(*) FROM stg.borrowers) - (SELECT COUNT(*) FROM clean.borrowers), 0,
   (SELECT COUNT(*) FROM clean.borrowers), 'Rejected: 600 exact duplicates + superseded versions.'),
 ('accounts', (SELECT COUNT(*) FROM stg.accounts), 0,
   (SELECT COUNT(*) FROM clean.accounts WHERE is_borrower_missing),
   (SELECT COUNT(*) FROM golden.dim_account), 'Flagged: missing borrower_id (kept, geography = UNKNOWN).'),
 ('whatsapp_events', (SELECT COUNT(*) FROM stg.whatsapp_events),
   (SELECT COUNT(*) FROM stg.whatsapp_events) - (SELECT COUNT(*) FROM clean.whatsapp_events), 0,
   (SELECT COUNT(*) FROM clean.whatsapp_events), 'Rejected: exact duplicate rows.'),
 ('sms_events', (SELECT COUNT(*) FROM stg.sms_events), 0, 0, (SELECT COUNT(*) FROM clean.sms_events), 'No change.'),
 ('field_visits', (SELECT COUNT(*) FROM stg.field_visits), 0,
   (SELECT COUNT(*) FROM clean.field_visits WHERE is_schedule_missing),
   (SELECT COUNT(*) FROM clean.field_visits), 'Flagged: missing scheduled_at.'),
 ('promises_to_pay', (SELECT COUNT(*) FROM stg.promises_to_pay), 0,
   (SELECT COUNT(*) FROM golden.fact_ptp WHERE reported_status = 'KEPT' AND NOT verified_any_payment),
   (SELECT COUNT(*) FROM golden.fact_ptp), 'Flagged: reported KEPT with no successful payment in the promise window.'),
 ('daily_targeting', (SELECT COUNT(*) FROM stg.daily_targeting), 0, 0, (SELECT COUNT(*) FROM clean.daily_targeting), 'No change.'),
 ('agent_sessions', (SELECT COUNT(*) FROM stg.agent_sessions), 0,
   (SELECT COUNT(*) FROM clean.agent_sessions WHERE source_timezone <> 'Asia/Kolkata'),
   (SELECT COUNT(*) FROM clean.agent_sessions), 'Corrected: UTC sessions shifted to IST.'),
 ('account_status_history', (SELECT COUNT(*) FROM stg.account_status_history), 0,
   (SELECT COUNT(*) FROM clean.account_status_history WHERE is_recorded_before_event),
   (SELECT COUNT(*) FROM clean.account_status_history), 'Flagged: recorded_at earlier than event_at.'),
 ('complaints', (SELECT COUNT(*) FROM stg.complaints), 0,
   (SELECT COUNT(*) FROM clean.complaints WHERE is_status_contradictory),
   (SELECT COUNT(*) FROM clean.complaints), 'Flagged: OPEN/INVESTIGATING but has a resolution date.'),
 ('campaigns', (SELECT COUNT(*) FROM stg.campaigns), 0, 0, (SELECT COUNT(*) FROM clean.campaigns), 'No change.'),
 ('vendor_telephony', (SELECT COUNT(*) FROM stg.vendor_telephony), 0, 0, (SELECT COUNT(*) FROM clean.vendor_telephony), 'No change.')
) t(source_table, raw_rows, rejected_rows, corrected_or_flagged_rows, golden_rows, rule);
