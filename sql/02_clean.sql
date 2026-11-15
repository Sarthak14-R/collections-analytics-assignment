-- =====================================================================
-- 02_clean.sql  |  STAGING -> CLEAN
-- One clean table per source. Every rule is deterministic and every
-- row keeps flags saying what was done to it, so nothing is silently lost.
--
-- TIMESTAMP RULE (applies everywhere)
--   Reporting timezone = Asia/Kolkata (IST), where the borrowers are.
--   Tables carrying a `timezone` column are converted with FIXED offsets.
--   None of the three zones observes daylight saving, so fixed offsets
--   are exact:   UTC -> +330 min | Asia/Kolkata -> 0 | Asia/Dubai -> +90 min
--   Tables WITHOUT a timezone column (payments, PTP, WhatsApp, SMS, field,
--   status history) are assumed to already be IST. This is an ASSUMPTION;
--   its worst-case effect is measured in 05_forensics.sql (check C).
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS clean;

CREATE OR REPLACE MACRO to_ist(ts, tz) AS
  ts + (CASE tz WHEN 'UTC' THEN 330 WHEN 'Asia/Dubai' THEN 90 ELSE 0 END) * INTERVAL 1 MINUTE;

-- ---------------------------------------------------------------------
-- PAYMENTS  (the most important table: it IS recovery)
-- Step 1  exact duplicate rows                -> keep one (ingestion replay)
-- Step 2  same payment_id, one copy lost its
--         payment_reference                   -> keep the copy that has it
-- Step 3  flag (do NOT drop) reference reuse  -> see forensics A
-- Step 4  flag status: only SUCCESS is money in the bank
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE clean.payments AS
WITH ranked AS (
  SELECT *,
         COUNT(*)     OVER (PARTITION BY payment_id) AS n_rows_for_id,
         ROW_NUMBER() OVER (PARTITION BY payment_id
                            ORDER BY (payment_reference IS NULL), payment_reference) AS rn
  FROM stg.payments
), one_per_id AS (
  SELECT * FROM ranked WHERE rn = 1
)
SELECT
  payment_id, account_id,
  borrower_id                       AS borrower_id_on_event,   -- unreliable, see DQ report
  event_at                          AS paid_at_ist,
  CAST(event_at AS DATE)            AS paid_date,
  DATE_TRUNC('month', event_at)::DATE AS paid_month,
  payment_reference, amount, payment_status, payment_method, provider_id,
  (payment_status = 'SUCCESS')      AS is_success,
  (n_rows_for_id > 1)               AS had_duplicate_row,
  (payment_reference IS NULL)       AS is_reference_missing,
  COALESCE(COUNT(*) OVER (PARTITION BY payment_reference) > 1
           AND payment_reference IS NOT NULL, FALSE)          AS is_reference_reused,
  -- rank inside a reused reference: 1 = first use. Used ONLY for sensitivity.
  ROW_NUMBER() OVER (PARTITION BY COALESCE(payment_reference, payment_id)
                     ORDER BY event_at, payment_id)           AS reference_use_seq
FROM one_per_id;

-- ---------------------------------------------------------------------
-- CALLS
-- Step 1 exact duplicate rows -> keep one
-- Step 2 same call_id with two different timestamps (conflicting copies)
--        -> keep the EARLIEST. Rationale: a call can only happen once and a
--           replayed/re-exported record can only be stamped later, not earlier.
-- Step 3 timestamps converted to IST
-- Step 4 missing agent_id -> 'UNKNOWN' (kept: the call still happened)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE clean.calls AS
WITH ranked AS (
  SELECT *,
         COUNT(*)                 OVER (PARTITION BY call_id) AS n_rows_for_id,
         COUNT(DISTINCT event_at) OVER (PARTITION BY call_id) AS n_timestamps,
         ROW_NUMBER() OVER (PARTITION BY call_id ORDER BY event_at) AS rn
  FROM stg.calls
)
SELECT
  call_id, account_id,
  event_at                               AS event_at_raw,
  timezone                               AS source_timezone,
  to_ist(event_at, timezone)             AS call_at_ist,
  CAST(to_ist(event_at, timezone) AS DATE)                AS call_date,
  DATE_TRUNC('month', to_ist(event_at, timezone))::DATE   AS call_month,
  HOUR(to_ist(event_at, timezone))       AS call_hour_ist,
  HOUR(event_at)                         AS call_hour_raw,
  COALESCE(agent_id, 'UNKNOWN')          AS agent_id,
  (agent_id IS NULL)                     AS is_agent_missing,
  campaign_id, direction, vendor_id, call_status, duration_sec,
  (call_status = 'ANSWERED')             AS is_answered,
  (n_rows_for_id > 1)                    AS had_duplicate_row,
  (n_timestamps > 1)                     AS had_conflicting_timestamp
FROM ranked WHERE rn = 1;

-- ---------------------------------------------------------------------
-- CALL DISPOSITIONS
-- Two codes mean the same thing: 'PTP' and 'PROMISE_TO_PAY'. Map to one.
-- A call can carry several dispositions; the LATEST one is the final one.
-- contact_class is OUR grouping (the raw data has none):
--   RPC      = we spoke to the borrower (right party)
--   NON_RPC  = somebody/nobody, but not the borrower
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE clean.call_dispositions AS
SELECT
  disposition_id, call_id, account_id AS account_id_on_event, agent_id,
  event_at AS disposed_at_ist, disposition_version,
  disposition_code AS disposition_code_raw,
  CASE WHEN disposition_code IN ('PTP','PROMISE_TO_PAY') THEN 'PTP' ELSE disposition_code END AS disposition_code,
  CASE WHEN disposition_code IN ('PTP','PROMISE_TO_PAY','PAID','PTP_BROKEN','CALLBACK','DISPUTE','REFUSED') THEN 'RPC'
       ELSE 'NON_RPC' END AS contact_class,          -- NO_CONTACT, WRONG_NUMBER
  ROW_NUMBER() OVER (PARTITION BY call_id ORDER BY event_at DESC, disposition_id DESC) = 1 AS is_final_for_call
FROM stg.call_dispositions;

CREATE OR REPLACE TABLE clean.call_attempts AS
SELECT attempt_id, call_id, account_id AS account_id_on_event, agent_id, event_at AS attempt_at,
       attempt_no, vendor_id, (vendor_id IS NULL) AS is_vendor_missing, attempt_status
FROM stg.call_attempts;

-- ---------------------------------------------------------------------
-- AGENTS  (30,000 rows for 1,000 agent_ids)
-- The table is a pile of overwritten versions: each agent_id has ~30 rows
-- with different names, employee codes, vendors, teams and join dates.
-- employee_code cannot be used to merge agents (each code sits on ~27 ids).
-- Decision: agent_id is the entity key (it is what every fact table uses);
-- the row with the latest updated_at is the "current" version.
-- joined_at / tenure / team / vendor are therefore LOW-TRUST attributes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE clean.agents AS
WITH v AS (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY agent_id ORDER BY updated_at DESC) AS rn,
         COUNT(*)                      OVER (PARTITION BY agent_id) AS n_versions,
         COUNT(DISTINCT employee_code) OVER (PARTITION BY agent_id) AS n_employee_codes,
         COUNT(DISTINCT joined_at)     OVER (PARTITION BY agent_id) AS n_join_dates,
         MIN(joined_at)                OVER (PARTITION BY agent_id) AS earliest_joined_at
  FROM stg.agents
)
SELECT agent_id, employee_code, agent_name, vendor_id, team, status,
       joined_at, earliest_joined_at, updated_at,
       n_versions, n_employee_codes, n_join_dates
FROM v WHERE rn = 1;

-- BORROWERS: 600 exact duplicate rows dropped, then latest version per id.
CREATE OR REPLACE TABLE clean.borrowers AS
WITH d AS (SELECT DISTINCT * FROM stg.borrowers),
v AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY borrower_id ORDER BY updated_at DESC) AS rn,
            COUNT(*) OVER (PARTITION BY borrower_id) AS n_versions,
            COUNT(DISTINCT city) OVER (PARTITION BY borrower_id) AS n_cities
  FROM d
)
SELECT borrower_id, name, phone, email, city, state, created_at, updated_at,
       n_versions, n_cities, (updated_at < created_at) AS has_impossible_timestamps
FROM v WHERE rn = 1;

-- ACCOUNTS: unique on account_id already. It is a point-in-time SNAPSHOT
-- (no history of dpd / outstanding), which limits every rate we compute.
CREATE OR REPLACE TABLE clean.accounts AS
SELECT account_id, borrower_id, (borrower_id IS NULL) AS is_borrower_missing,
       loan_type, principal_amount, outstanding_amount, dpd,
       CASE WHEN dpd = 0 THEN '0 current' WHEN dpd < 30 THEN '1-29'
            WHEN dpd < 60 THEN '30-59' WHEN dpd < 90 THEN '60-89' ELSE '90+' END AS dpd_bucket,
       risk_segment, status AS snapshot_status, opened_at,
       timezone AS account_timezone, schema_version
FROM stg.accounts;

CREATE OR REPLACE TABLE clean.whatsapp_events AS
SELECT DISTINCT whatsapp_event_id, account_id, event_at AS event_at_ist, message_id,
       event_type, template_code, provider_id
FROM stg.whatsapp_events;            -- 600 exact duplicate rows removed

CREATE OR REPLACE TABLE clean.sms_events AS
SELECT sms_event_id, account_id, event_at AS event_at_ist, message_id, event_type, template_code, provider_id
FROM stg.sms_events;

CREATE OR REPLACE TABLE clean.field_visits AS
SELECT visit_id, account_id, agent_id, event_at AS visit_at_ist, scheduled_at,
       (scheduled_at IS NULL) AS is_schedule_missing, visit_type, outcome, latitude, longitude
FROM stg.field_visits;

CREATE OR REPLACE TABLE clean.promises_to_pay AS
SELECT ptp_id, account_id, agent_id, event_at AS promised_at_ist, promised_date, promised_amount,
       status AS reported_status, source
FROM stg.promises_to_pay;

CREATE OR REPLACE TABLE clean.daily_targeting AS
SELECT target_id, account_id, campaign_id, target_date,
       DATE_TRUNC('month', target_date)::DATE AS target_month,
       priority, recommended_channel, status
FROM stg.daily_targeting;

CREATE OR REPLACE TABLE clean.campaigns AS
SELECT *, (strategy_version IN ('v2','v3')) AS is_new_strategy FROM stg.campaigns;

CREATE OR REPLACE TABLE clean.agent_sessions AS
SELECT session_id, agent_id, channel, device_id, timezone AS source_timezone,
       to_ist(login_at, timezone)  AS login_at_ist,
       to_ist(logout_at, timezone) AS logout_at_ist,
       DATE_TRUNC('month', to_ist(login_at, timezone))::DATE AS session_month,
       EPOCH(logout_at) - EPOCH(login_at) AS session_seconds
FROM stg.agent_sessions;

-- STATUS HISTORY: half the rows were "recorded" BEFORE the event happened.
-- event_at is kept as the business time; recorded_at only as an audit field.
CREATE OR REPLACE TABLE clean.account_status_history AS
SELECT history_id, account_id, event_at AS status_at_ist, recorded_at, status, changed_by, source,
       (recorded_at < event_at) AS is_recorded_before_event,
       (EPOCH(recorded_at) - EPOCH(event_at)) / 3600.0 AS record_lag_hours
FROM stg.account_status_history;

CREATE OR REPLACE TABLE clean.complaints AS
SELECT complaint_id, account_id, event_at AS complaint_at_ist, complaint_type, severity, status, source, resolution_at,
       (status IN ('OPEN','INVESTIGATING') AND resolution_at IS NOT NULL) AS is_status_contradictory
FROM stg.complaints;

CREATE OR REPLACE TABLE clean.vendor_telephony AS SELECT * FROM stg.vendor_telephony;
