-- =====================================================================
-- 05_forensics.sql  |  Part 2 - seven forensic checks (A..G)
-- Each block is a named, stand-alone query:  "-- name: <id>"
-- Run one with:  from src.sqlq import q;  q(con, 'A1_duplicate_payment_inflation')
-- =====================================================================

-- name: A1_duplicate_payment_inflation
-- Does duplicate ingestion inflate recovery? Raw SUCCESS rows vs unique payments.
SELECT month_label,
       ROUND(naive_recovery_raw_rows/1e7, 3) AS raw_cr,
       ROUND(recovery_amount/1e7, 3)         AS clean_cr,
       ROUND(100*(naive_recovery_raw_rows/recovery_amount - 1), 2) AS inflation_pct
FROM golden.metrics_monthly ORDER BY month_start;

-- name: A2_duplicate_types
SELECT 'raw rows' AS item, COUNT(*) AS n FROM stg.payments
UNION ALL SELECT 'unique payment_id', COUNT(DISTINCT payment_id) FROM stg.payments
UNION ALL SELECT 'payment_ids appearing twice', COUNT(*) FROM (SELECT 1 FROM stg.payments GROUP BY payment_id HAVING COUNT(*) > 1)
UNION ALL SELECT '  ..of which copy differs only by a NULL reference', COUNT(*) FROM (
            SELECT 1 FROM stg.payments GROUP BY payment_id
            HAVING COUNT(*) > 1 AND COUNT(payment_reference) < COUNT(*))
UNION ALL SELECT 'rows with missing payment_reference (after dedup)', COUNT(*) FROM clean.payments WHERE is_reference_missing
UNION ALL SELECT 'references used by >1 payment_id', COUNT(*) FROM (
            SELECT 1 FROM clean.payments WHERE payment_reference IS NOT NULL GROUP BY payment_reference HAVING COUNT(*) > 1)
UNION ALL SELECT 'payments sharing a reference', COUNT(*) FROM clean.payments WHERE is_reference_reused;

-- name: A3_is_reference_reuse_a_retry
-- A retry looks like: same account, same amount, close in time. Reused references show none of that.
WITH pairs AS (
  SELECT a.payment_reference,
         (a.account_id = b.account_id) AS same_account,
         (a.amount = b.amount)         AS same_amount,
         ABS(DATE_DIFF('day', a.paid_at_ist, b.paid_at_ist)) AS days_apart
  FROM clean.payments a JOIN clean.payments b
    ON a.payment_reference = b.payment_reference AND a.payment_id < b.payment_id)
SELECT COUNT(*) AS reused_pairs, SUM(same_account::INT) AS same_account, SUM(same_amount::INT) AS same_amount,
       SUM((days_apart <= 3)::INT) AS within_3_days, MEDIAN(days_apart) AS median_days_apart
FROM pairs;

-- name: A4_true_retry_candidates
-- Independent of reference: same account + same amount + within 72h, different payment_id.
SELECT COUNT(*) AS retry_like_pairs
FROM clean.payments a JOIN clean.payments b
  ON a.account_id = b.account_id AND a.amount = b.amount AND a.payment_id < b.payment_id
 AND ABS(EPOCH(a.paid_at_ist) - EPOCH(b.paid_at_ist)) <= 72*3600;

-- name: A5_status_definition_impact
-- How much "recovery" depends on which statuses you count.
SELECT payment_status, COUNT(*) AS n, ROUND(SUM(amount)/1e7, 2) AS amount_cr,
       ROUND(100.0*SUM(amount)/SUM(SUM(amount)) OVER (), 1) AS pct_of_all
FROM golden.fact_payment WHERE paid_month < DATE '2026-08-01' GROUP BY 1 ORDER BY 3 DESC;

-- name: A6_reference_dedup_sensitivity
-- If we had (wrongly) kept only the first payment per reference, what happens? It manufactures a decline.
SELECT month_label, ROUND(recovery_amount/1e7,2) AS clean_cr,
       ROUND(recovery_if_reused_refs_removed/1e7,2) AS if_dedup_on_reference_cr,
       ROUND(100*(recovery_if_reused_refs_removed/recovery_amount-1),1) AS pct_removed
FROM golden.metrics_monthly ORDER BY month_start;

-- name: B1_last_touch_attribution
-- Share of recovery that has ANY effective contact in the previous 7 days.
SELECT last_touch_channel_7d, COUNT(*) AS payments, ROUND(SUM(amount)/1e7,2) AS amount_cr,
       ROUND(100.0*SUM(amount)/SUM(SUM(amount)) OVER (),1) AS pct
FROM golden.fact_payment WHERE is_recovery GROUP BY 1 ORDER BY 3 DESC;

-- name: B2_naive_latest_campaign_attribution
-- "Credit the latest campaign that ever called the account" - how defensible is that?
WITH x AS (
  SELECT p.payment_id, p.amount, p.paid_at_ist, p.naive_latest_campaign, k.start_at, k.end_at
  FROM golden.fact_payment p LEFT JOIN clean.campaigns k ON k.campaign_id = p.naive_latest_campaign
  WHERE p.is_recovery)
SELECT COUNT(*) AS payments,
       ROUND(100.0*AVG((naive_latest_campaign IS NOT NULL)::INT),1) AS pct_credited_to_a_campaign,
       ROUND(100.0*AVG((paid_at_ist BETWEEN start_at AND end_at)::INT) FILTER (naive_latest_campaign IS NOT NULL),1)
            AS pct_of_credited_where_campaign_was_even_live
FROM x;

-- name: B3_attribution_window_placebo
-- For windows of N days: % of payments with an effective contact in the N days BEFORE
-- vs. the N days AFTER the payment. A contact AFTER a payment cannot have caused it,
-- so "after" is the rate you get from coincidence alone.
WITH w AS (SELECT UNNEST([1,3,7,14,30,60]) AS n_days),
p AS (SELECT payment_id, account_id, paid_at_ist FROM golden.fact_payment
      WHERE is_recovery AND paid_date BETWEEN DATE '2026-03-02' AND DATE '2026-06-09'),  -- 60d of data on both sides
t AS (SELECT account_id, touch_at FROM golden.fact_touch WHERE is_effective_contact)
SELECT w.n_days,
       ROUND(100.0*COUNT(DISTINCT CASE WHEN t.touch_at <  p.paid_at_ist AND t.touch_at >= p.paid_at_ist - w.n_days*INTERVAL 1 DAY THEN p.payment_id END)/COUNT(DISTINCT p.payment_id),2) AS pct_contact_before,
       ROUND(100.0*COUNT(DISTINCT CASE WHEN t.touch_at >  p.paid_at_ist AND t.touch_at <= p.paid_at_ist + w.n_days*INTERVAL 1 DAY THEN p.payment_id END)/COUNT(DISTINCT p.payment_id),2) AS pct_contact_after_placebo
FROM w CROSS JOIN p LEFT JOIN t USING (account_id)
GROUP BY 1 ORDER BY 1;

-- name: C1_timezone_misclassification
-- How many calls land in a different hour / day / month once converted to IST?
SELECT source_timezone, COUNT(*) AS calls,
       ROUND(100.0*AVG((call_hour_ist <> call_hour_raw)::INT),1)                         AS pct_wrong_hour,
       ROUND(100.0*AVG((call_date <> CAST(event_at_raw AS DATE))::INT),1)                AS pct_wrong_day,
       ROUND(100.0*AVG((call_month <> DATE_TRUNC('month', event_at_raw)::DATE)::INT),2)  AS pct_wrong_month
FROM golden.fact_call GROUP BY ROLLUP(1) ORDER BY 1;

-- name: C2_compliance_window_raw_vs_ist
-- Calls outside 08:00-19:00 (permitted borrower-contact hours) - raw clock vs IST clock.
SELECT ROUND(100.0*AVG((call_hour_raw < 8 OR call_hour_raw >= 19)::INT),1) AS pct_outside_hours_raw_clock,
       ROUND(100.0*AVG((call_hour_ist < 8 OR call_hour_ist >= 19)::INT),1) AS pct_outside_hours_ist,
       SUM((call_hour_ist < 8 OR call_hour_ist >= 19)::INT) AS calls_outside_hours_ist
FROM golden.fact_call;

-- name: C3_payment_timezone_sensitivity
-- Payments carry no timezone. Worst case: they are in the ACCOUNT's timezone. Effect on monthly recovery?
WITH x AS (
  SELECT p.amount, p.paid_month AS m_assumed_ist,
         DATE_TRUNC('month', to_ist(p.paid_at_ist, a.account_timezone))::DATE AS m_if_account_tz
  FROM golden.fact_payment p JOIN clean.accounts a USING (account_id) WHERE p.is_recovery)
SELECT STRFTIME(m,'%Y-%m') AS month_label,
       ROUND(SUM(amount) FILTER (m_assumed_ist = m)/1e7,3)   AS recovery_cr_assumed_ist,
       ROUND(SUM(amount) FILTER (m_if_account_tz = m)/1e7,3) AS recovery_cr_if_account_tz,
       ROUND(100*(SUM(amount) FILTER (m_if_account_tz = m)/SUM(amount) FILTER (m_assumed_ist = m)-1),2) AS diff_pct
FROM x CROSS JOIN (SELECT month_start AS m FROM golden.dim_month) GROUP BY m ORDER BY m;

-- name: D1_disposition_codes_by_version
SELECT disposition_code_raw, disposition_version, COUNT(*) AS n
FROM clean.call_dispositions GROUP BY 1,2 ORDER BY 1,2;

-- name: D2_ptp_code_share_by_month
-- If the code had been switched mid-year, one spelling would fade out and the other fade in.
SELECT STRFTIME(disposed_at_ist,'%Y-%m') AS month_label,
       COUNT(*) FILTER (disposition_code_raw='PTP')            AS code_PTP,
       COUNT(*) FILTER (disposition_code_raw='PROMISE_TO_PAY') AS code_PROMISE_TO_PAY,
       ROUND(100.0*COUNT(*) FILTER (disposition_code='PTP')/COUNT(*),1)      AS ptp_share_merged_pct,
       ROUND(100.0*COUNT(*) FILTER (disposition_code_raw='PTP')/COUNT(*),1)  AS ptp_share_if_one_code_ignored_pct
FROM clean.call_dispositions GROUP BY 1 ORDER BY 1;

-- name: D3_version_mix_by_month
SELECT STRFTIME(disposed_at_ist,'%Y-%m') AS month_label,
       ROUND(100.0*AVG((disposition_version='legacy')::INT),1) AS pct_legacy,
       ROUND(100.0*AVG((disposition_version='v1')::INT),1) AS pct_v1,
       ROUND(100.0*AVG((disposition_version='v2')::INT),1) AS pct_v2
FROM clean.call_dispositions GROUP BY 1 ORDER BY 1;

-- name: D4_disposition_vs_call_status
-- Contradiction: "we spoke to the borrower" dispositions sitting on calls that were never answered.
SELECT call_status, COUNT(*) FILTER (has_disposition) AS dispositioned,
       COUNT(*) FILTER (is_rpc) AS rpc_valid, COUNT(*) FILTER (is_rpc_on_unanswered_call) AS rpc_claimed_but_unanswered
FROM golden.fact_call GROUP BY 1 ORDER BY 1;

-- name: D5_vendor_status_usage
SELECT v.status AS vendor_status, COUNT(DISTINCT c.vendor_id) AS vendors, COUNT(*) AS calls,
       ROUND(100.0*AVG(c.is_answered::INT),2) AS answered_pct
FROM golden.fact_call c JOIN clean.vendor_telephony v USING (vendor_id) GROUP BY 1;

-- name: E1_agent_identity
SELECT (SELECT COUNT(*) FROM stg.agents)                              AS agent_rows,
       (SELECT COUNT(DISTINCT agent_id) FROM stg.agents)              AS agent_ids,
       (SELECT COUNT(DISTINCT employee_code) FROM stg.agents)         AS employee_codes,
       (SELECT ROUND(AVG(n_employee_codes),1) FROM clean.agents)      AS avg_employee_codes_per_agent_id,
       (SELECT ROUND(AVG(n),1) FROM (SELECT COUNT(DISTINCT agent_id) n FROM stg.agents GROUP BY employee_code)) AS avg_agent_ids_per_employee_code,
       (SELECT ROUND(AVG(n),1) FROM (SELECT COUNT(DISTINCT agent_name) n FROM stg.agents GROUP BY agent_id))    AS avg_names_per_agent_id,
       (SELECT ROUND(AVG(n),1) FROM (SELECT COUNT(DISTINCT vendor_id) n FROM stg.agents GROUP BY agent_id))     AS avg_vendors_per_agent_id,
       (SELECT COUNT(*) FROM stg.agents WHERE updated_at < joined_at) AS rows_updated_before_joined;

-- name: E2_calls_by_agent_current_status
SELECT COALESCE(a.status,'UNKNOWN AGENT') AS agent_current_status, COUNT(*) AS calls,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS pct
FROM golden.fact_call c LEFT JOIN golden.dim_agent a USING (agent_id) GROUP BY 1 ORDER BY 2 DESC;

-- name: E3_borrower_identity
SELECT (SELECT COUNT(*) FROM stg.borrowers) AS borrower_rows,
       (SELECT COUNT(*) FROM stg.borrowers) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM stg.borrowers)) AS exact_duplicate_rows,
       (SELECT COUNT(*) FROM clean.borrowers) AS borrower_ids,
       (SELECT COUNT(*) FROM clean.borrowers WHERE n_cities > 1) AS ids_with_more_than_one_city,
       (SELECT COUNT(DISTINCT borrower_id) FROM clean.accounts WHERE borrower_id NOT IN (SELECT borrower_id FROM clean.borrowers)) AS borrower_ids_on_accounts_missing_from_master,
       (SELECT COUNT(*) FROM clean.accounts WHERE is_borrower_missing) AS accounts_without_borrower,
       (SELECT ROUND(100.0*AVG((p.borrower_id_on_event = a.borrower_id)::INT),3) FROM clean.payments p JOIN clean.accounts a USING (account_id)) AS pct_payments_whose_borrower_matches_account;

-- name: F1_portfolio_vintage
-- A newly acquired portfolio would show up as a block of accounts opened (or first seen) mid-period.
SELECT STRFTIME(opened_at,'%Y') || '-H' || CASE WHEN MONTH(opened_at)<=6 THEN '1' ELSE '2' END AS vintage,
       COUNT(*) AS accounts, ROUND(AVG(dpd),1) AS avg_dpd, ROUND(AVG(outstanding_amount)) AS avg_outstanding,
       ROUND(100.0*AVG((risk_segment IN ('HIGH','NPA'))::INT),1) AS pct_high_or_npa
FROM golden.dim_account GROUP BY 1 ORDER BY 1;

-- name: F2_first_activity_month
-- When does each account first appear in ANY operational table? (a new portfolio = a late spike)
WITH f AS (SELECT account_id, MIN(touch_at) AS first_seen FROM golden.fact_touch GROUP BY 1)
SELECT STRFTIME(first_seen,'%Y-%m') AS first_seen_month, COUNT(*) AS accounts FROM f GROUP BY 1 ORDER BY 1;

-- name: F3_worked_mix_by_month
SELECT STRFTIME(m.month_start,'%Y-%m') AS month_label,
       ROUND(AVG(a.dpd),1) AS avg_dpd_worked,
       ROUND(100.0*AVG((a.dpd >= 90)::INT),1) AS pct_dpd_90_plus,
       ROUND(100.0*AVG((a.risk_segment IN ('HIGH','NPA'))::INT),1) AS pct_high_or_npa,
       ROUND(100.0*AVG((a.loan_type='PERSONAL')::INT),1) AS pct_personal,
       ROUND(AVG(a.outstanding_amount)) AS avg_outstanding
FROM golden.fact_account_month m JOIN golden.dim_account a USING (account_id)
WHERE m.n_touches > 0 GROUP BY 1 ORDER BY 1;

-- name: G1_denominator_by_month
-- Are the populations used as denominators shrinking?
SELECT month_label, accounts_targeted, accounts_worked, accounts_dialled, n_paying_accounts,
       ROUND(100.0*n_paying_accounts/30000,2) AS payer_rate_full_book_pct
FROM golden.metrics_monthly ORDER BY month_start;

-- name: G2_targeting_status_by_month
SELECT STRFTIME(target_month,'%Y-%m') AS month_label, COUNT(*) AS target_rows,
       ROUND(100.0*AVG((status='CONTACTED')::INT),1) AS pct_contacted,
       ROUND(100.0*AVG((status='QUEUED')::INT),1) AS pct_queued,
       ROUND(100.0*AVG((status='SKIPPED')::INT),1) AS pct_skipped,
       ROUND(100.0*AVG((status='EXPIRED')::INT),1) AS pct_expired
FROM clean.daily_targeting GROUP BY 1 ORDER BY 1;

-- name: G3_do_non_payers_drop_out
-- If failures were being removed, accounts that did NOT pay in month m would be
-- less likely to be targeted/worked in month m+1 than accounts that paid.
SELECT a.paid_flag AS paid_in_month_m, COUNT(*) AS account_months,
       ROUND(100.0*AVG((b.n_target_rows > 0)::INT),2) AS pct_targeted_next_month,
       ROUND(100.0*AVG((b.n_touches > 0)::INT),2)     AS pct_worked_next_month
FROM golden.fact_account_month a
JOIN golden.fact_account_month b ON b.account_id = a.account_id AND b.month_start = a.month_start + INTERVAL 1 MONTH
WHERE a.month_start <= DATE '2026-06-01' GROUP BY 1;

-- name: G4_terminal_status_accounts_still_in_play
-- Snapshot status says WRITEOFF/CLOSED/PAID - yet they are still worked and still pay.
SELECT a.snapshot_status, COUNT(DISTINCT a.account_id) AS accounts,
       ROUND(100.0*AVG((m.n_touches > 0)::INT),1) AS pct_account_months_worked,
       ROUND(100.0*AVG(m.paid_flag::INT),2)        AS payer_rate_pct
FROM golden.dim_account a JOIN golden.fact_account_month m USING (account_id)
WHERE m.month_start < DATE '2026-08-01' GROUP BY 1 ORDER BY 1;

-- name: H1_campaign_definition_consistency
SELECT (SELECT COUNT(*) FROM clean.campaigns) AS campaigns,
       (SELECT COUNT(DISTINCT campaign_name) FROM clean.campaigns) AS campaign_names,
       (SELECT MAX(n) FROM (SELECT COUNT(DISTINCT target_definition) n FROM clean.campaigns GROUP BY campaign_name)) AS max_target_definitions_per_name,
       (SELECT ROUND(100.0*AVG(is_inside_campaign_window::INT),1) FROM golden.fact_call) AS pct_calls_inside_campaign_dates,
       (SELECT ROUND(100.0*AVG((t.target_date BETWEEN k.start_at AND k.end_at)::INT),1)
          FROM clean.daily_targeting t JOIN clean.campaigns k USING (campaign_id)) AS pct_targets_inside_campaign_dates,
       (SELECT ROUND(100.0*AVG((t.recommended_channel = k.channel)::INT),1)
          FROM clean.daily_targeting t JOIN clean.campaigns k USING (campaign_id)) AS pct_targets_where_channel_matches_campaign;

-- name: H2_status_history_reliability
SELECT COUNT(*) AS rows, ROUND(100.0*AVG(is_recorded_before_event::INT),1) AS pct_recorded_before_event,
       ROUND(MIN(record_lag_hours),1) AS min_lag_h, ROUND(MAX(record_lag_hours),1) AS max_lag_h,
       (SELECT ROUND(100.0*AVG((h.status = a.snapshot_status)::INT),1)
          FROM (SELECT account_id, ARG_MAX(status, status_at_ist) AS status FROM clean.account_status_history GROUP BY 1) h
          JOIN clean.accounts a USING (account_id)) AS pct_latest_history_status_equals_account_status
FROM clean.account_status_history;
