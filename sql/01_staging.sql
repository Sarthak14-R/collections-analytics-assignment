-- =====================================================================
-- 01_staging.sql  |  RAW -> STAGING
-- Purpose : load every raw CSV exactly as delivered, with explicit types.
-- Rule    : NO business logic here. Nothing is dropped, nothing is fixed.
--           Staging must always reconcile 1:1 with the raw file row count.
-- Engine  : DuckDB.  ${RAW_DIR} is substituted by src/run_pipeline.py
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS stg;

CREATE OR REPLACE TABLE stg.borrowers AS
SELECT * FROM read_csv('${RAW_DIR}/borrowers.csv', header = true, columns = {
  'borrower_id':'VARCHAR','name':'VARCHAR','phone':'VARCHAR','email':'VARCHAR','city':'VARCHAR',
  'created_at':'TIMESTAMP','updated_at':'TIMESTAMP','state':'VARCHAR'});

CREATE OR REPLACE TABLE stg.accounts AS
SELECT * FROM read_csv('${RAW_DIR}/accounts.csv', header = true, columns = {
  'account_id':'VARCHAR','borrower_id':'VARCHAR','loan_type':'VARCHAR','principal_amount':'DOUBLE',
  'outstanding_amount':'DOUBLE','dpd':'INTEGER','risk_segment':'VARCHAR','status':'VARCHAR',
  'opened_at':'TIMESTAMP','timezone':'VARCHAR','schema_version':'VARCHAR'});

CREATE OR REPLACE TABLE stg.agents AS
SELECT * FROM read_csv('${RAW_DIR}/agents.csv', header = true, columns = {
  'agent_id':'VARCHAR','employee_code':'VARCHAR','agent_name':'VARCHAR','vendor_id':'VARCHAR',
  'team':'VARCHAR','status':'VARCHAR','joined_at':'TIMESTAMP','updated_at':'TIMESTAMP'});

CREATE OR REPLACE TABLE stg.agent_sessions AS
SELECT * FROM read_csv('${RAW_DIR}/agent_sessions.csv', header = true, columns = {
  'session_id':'VARCHAR','agent_id':'VARCHAR','login_at':'TIMESTAMP','channel':'VARCHAR',
  'device_id':'VARCHAR','timezone':'VARCHAR','logout_at':'TIMESTAMP'});

CREATE OR REPLACE TABLE stg.campaigns AS
SELECT * FROM read_csv('${RAW_DIR}/campaigns.csv', header = true, columns = {
  'campaign_id':'VARCHAR','campaign_name':'VARCHAR','channel':'VARCHAR','strategy_version':'VARCHAR',
  'start_at':'TIMESTAMP','target_definition':'VARCHAR','end_at':'TIMESTAMP'});

CREATE OR REPLACE TABLE stg.daily_targeting AS
SELECT * FROM read_csv('${RAW_DIR}/daily_targeting.csv', header = true, columns = {
  'target_id':'VARCHAR','account_id':'VARCHAR','campaign_id':'VARCHAR','target_date':'DATE',
  'priority':'INTEGER','recommended_channel':'VARCHAR','status':'VARCHAR'});

CREATE OR REPLACE TABLE stg.calls AS
SELECT * FROM read_csv('${RAW_DIR}/calls.csv', header = true, columns = {
  'call_id':'VARCHAR','account_id':'VARCHAR','borrower_id':'VARCHAR','event_at':'TIMESTAMP',
  'agent_id':'VARCHAR','campaign_id':'VARCHAR','direction':'VARCHAR','vendor_id':'VARCHAR',
  'call_status':'VARCHAR','duration_sec':'INTEGER','timezone':'VARCHAR'});

CREATE OR REPLACE TABLE stg.call_attempts AS
SELECT * FROM read_csv('${RAW_DIR}/call_attempts.csv', header = true, columns = {
  'attempt_id':'VARCHAR','account_id':'VARCHAR','borrower_id':'VARCHAR','event_at':'TIMESTAMP',
  'call_id':'VARCHAR','agent_id':'VARCHAR','attempt_no':'INTEGER','vendor_id':'VARCHAR',
  'attempt_status':'VARCHAR'});

CREATE OR REPLACE TABLE stg.call_dispositions AS
SELECT * FROM read_csv('${RAW_DIR}/call_dispositions.csv', header = true, columns = {
  'disposition_id':'VARCHAR','account_id':'VARCHAR','borrower_id':'VARCHAR','event_at':'TIMESTAMP',
  'call_id':'VARCHAR','agent_id':'VARCHAR','disposition_code':'VARCHAR','disposition_version':'VARCHAR'});

CREATE OR REPLACE TABLE stg.whatsapp_events AS
SELECT * FROM read_csv('${RAW_DIR}/whatsapp_events.csv', header = true, columns = {
  'whatsapp_event_id':'VARCHAR','account_id':'VARCHAR','borrower_id':'VARCHAR','event_at':'TIMESTAMP',
  'message_id':'VARCHAR','event_type':'VARCHAR','template_code':'VARCHAR','provider_id':'VARCHAR'});

CREATE OR REPLACE TABLE stg.sms_events AS
SELECT * FROM read_csv('${RAW_DIR}/sms_events.csv', header = true, columns = {
  'sms_event_id':'VARCHAR','account_id':'VARCHAR','borrower_id':'VARCHAR','event_at':'TIMESTAMP',
  'message_id':'VARCHAR','event_type':'VARCHAR','template_code':'VARCHAR','provider_id':'VARCHAR'});

CREATE OR REPLACE TABLE stg.field_visits AS
SELECT * FROM read_csv('${RAW_DIR}/field_visits.csv', header = true, columns = {
  'visit_id':'VARCHAR','account_id':'VARCHAR','borrower_id':'VARCHAR','event_at':'TIMESTAMP',
  'agent_id':'VARCHAR','visit_type':'VARCHAR','outcome':'VARCHAR','latitude':'DOUBLE',
  'longitude':'DOUBLE','scheduled_at':'TIMESTAMP'});

CREATE OR REPLACE TABLE stg.promises_to_pay AS
SELECT * FROM read_csv('${RAW_DIR}/promises_to_pay.csv', header = true, columns = {
  'ptp_id':'VARCHAR','account_id':'VARCHAR','borrower_id':'VARCHAR','event_at':'TIMESTAMP',
  'agent_id':'VARCHAR','promised_amount':'DOUBLE','promised_date':'TIMESTAMP','status':'VARCHAR',
  'source':'VARCHAR'});

CREATE OR REPLACE TABLE stg.payments AS
SELECT * FROM read_csv('${RAW_DIR}/payments.csv', header = true, columns = {
  'payment_id':'VARCHAR','account_id':'VARCHAR','borrower_id':'VARCHAR','event_at':'TIMESTAMP',
  'payment_reference':'VARCHAR','amount':'DOUBLE','payment_status':'VARCHAR',
  'payment_method':'VARCHAR','provider_id':'VARCHAR'});

CREATE OR REPLACE TABLE stg.vendor_telephony AS
SELECT * FROM read_csv('${RAW_DIR}/vendor_telephony.csv', header = true, columns = {
  'vendor_id':'VARCHAR','vendor_name':'VARCHAR','vendor_account_id':'VARCHAR','timezone':'VARCHAR',
  'status':'VARCHAR','schema_version':'VARCHAR'});

CREATE OR REPLACE TABLE stg.complaints AS
SELECT * FROM read_csv('${RAW_DIR}/complaints.csv', header = true, columns = {
  'complaint_id':'VARCHAR','account_id':'VARCHAR','borrower_id':'VARCHAR','event_at':'TIMESTAMP',
  'complaint_type':'VARCHAR','severity':'VARCHAR','status':'VARCHAR','source':'VARCHAR',
  'resolution_at':'TIMESTAMP'});

CREATE OR REPLACE TABLE stg.account_status_history AS
SELECT * FROM read_csv('${RAW_DIR}/account_status_history.csv', header = true, columns = {
  'history_id':'VARCHAR','account_id':'VARCHAR','borrower_id':'VARCHAR','event_at':'TIMESTAMP',
  'status':'VARCHAR','changed_by':'VARCHAR','source':'VARCHAR','recorded_at':'TIMESTAMP'});
