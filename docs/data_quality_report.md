# Data quality report

Every number here is reproducible: the query name in brackets lives in `sql/05_forensics.sql`, and the cleaning rules live in `sql/02_clean.sql`.

## 1. Raw → Rejected / Corrected → Golden

| Source table | Raw rows | Rejected | Corrected or flagged | Golden rows | Rule |
|---|---:|---:|---:|---:|---|
| payments | 25,500 | 500 | 7,586 | 25,000 | Duplicate rows per `payment_id` removed. Reused or missing references flagged, not removed. 17,534 `SUCCESS` rows count as recovery. |
| calls | 91,350 | 1,402 | 60,494 | 89,948 | 1,350 duplicate rows and 52 calls outside the window removed. Timezone, missing agent, conflicting timestamp corrected. |
| call_dispositions | 35,000 | 0 | 3,926 | 35,000 | `PROMISE_TO_PAY` mapped to `PTP`. Latest per call marked final. |
| call_attempts | 120,000 | 0 | 2,400 | 120,000 | Missing `vendor_id` flagged. |
| agents | 30,000 | 29,000 | 0 | 1,000 | Latest version per `agent_id` kept. |
| borrowers | 30,600 | 19,585 | 0 | 11,015 | 600 exact duplicates, then latest version per `borrower_id`. |
| accounts | 30,000 | 0 | 455 | 30,000 | Missing `borrower_id` flagged. |
| whatsapp_events | 60,600 | 600 | 0 | 60,000 | Exact duplicates removed. |
| promises_to_pay | 18,000 | 0 | 4,273 | 18,000 | Reported `KEPT` with no payment in the promise window flagged. |
| agent_sessions | 15,000 | 0 | 7,494 | 15,000 | UTC sessions shifted to IST. |
| account_status_history | 60,000 | 0 | 30,191 | 60,000 | `recorded_at` earlier than `event_at` flagged. |
| complaints | 8,000 | 0 | 4,101 | 8,000 | Open status with a resolution date flagged. |
| sms_events, field_visits, daily_targeting, campaigns, vendor_telephony | 115,135 | 0 | 250 | 115,135 | 250 field visits without `scheduled_at` flagged. |

**Impact of the cleaning decisions on the headline (Jan to Jul):**

| Definition of recovery | Rs Cr | Against golden |
|---|---:|---:|
| Every payment row, any status | 184.5 | +45% |
| Raw rows with status `SUCCESS` | 129.3 | +1.9% |
| **Golden: unique payments with status `SUCCESS`** | **126.8** | n/a |
| If one payment were kept per reference (rejected rule) | 108.2 | −15%, and it manufactures a falling trend |

## 2. Issues found

| # | Issue | How it was detected | Treatment | Business impact |
|---|---|---|---|---|
| 1 | **Duplicate payment rows.** 500 `payment_id`s appear twice (486 identical, 14 where one copy lost its reference). | Count rows per `payment_id` [A2] | Keep one row per id, preferring the copy with a reference. | Recovery overstated about 2% in every month [A1]. Raises the level, not the trend. |
| 2 | **Payment reference is not unique.** 3,407 references are shared by 7,218 payments. | Count ids per reference; compare account, amount and date within shared pairs [A3, A4] | **Kept and flagged.** Zero shared pairs are on the same account or the same amount; median gap 65 days. These are not retries. | Deduplicating on reference would remove Rs 18.6 Cr of real money and invent a decline of up to 28% by July [A6]. |
| 3 | **Status ignored.** 30% of payment value is `FAILED`, `PENDING` or `REVERSED`. | Sum by status [A5] | Only `SUCCESS` is recovery. `PENDING` and `REVERSED` are reported separately. | Summing all rows overstates recovery by 43% to 45%. |
| 4 | **Month length.** | Recovery per calendar day against monthly total [T1] | Every volume metric is reported per day. | Explains the reported +11% (Feb to Mar: +10.7% days, +0.3% per day). |
| 5 | **Three timezones in `calls`** (UTC, Asia/Kolkata, Asia/Dubai, a third each). `agent_sessions` has two. | Group by `timezone`; compare hour, day and month before and after conversion [C1] | Convert to IST with fixed offsets (none of the zones has daylight saving). | 67% of calls in the wrong hour, 9.7% on the wrong day, 0.34% in the wrong month. Calling-hour analysis is invalid without the fix; monthly totals barely move. |
| 6 | **No timezone on payments, promises, WhatsApp, SMS, field visits.** | Schema review | Assumed IST. Sensitivity test: treat payments as being in the account's zone [C3]. | Monthly recovery moves by less than 0.5%. |
| 7 | **Conflicting timestamps.** 79 `call_id`s have two rows that differ only in `event_at`, days apart. | Distinct `event_at` per `call_id` | Keep the earliest. | 0.09% of calls. Negligible. |
| 8 | **Two codes for one disposition:** `PTP` and `PROMISE_TO_PAY`, in every version and every month. | Code by version by month [D1, D2] | Map both to `PTP`. | A report that knows one code shows half the promises (11% share against 22%). No switch date, so no artificial trend. |
| 9 | **Right-party dispositions on unanswered calls.** 17,868 such rows. | Join final disposition to `call_status` [D4] | RPC requires the call to be `ANSWERED`. | RPC rate is 6% of dialled accounts, against 77% on the usual definition. |
| 10 | **Only 32% of calls have a disposition.** | Left join | Reported as coverage; denominators use dialled accounts. | Any rate with "dispositioned calls" underneath describes a third of activity. |
| 11 | **Agent identity.** 30,000 rows for 1,000 ids; each id has on average 29.6 employee codes, 9.5 names and 13 vendors; each employee code sits on about 27 ids. | Distinct counts per id and per code [E1] | `agent_id` is the entity. Latest version supplies attributes, marked low-trust. | Agent tenure, team and vendor-of-agent cannot be trusted. Agent-level ranking would be meaningless. |
| 12 | **Borrower identity.** 8,159 of 11,015 ids have more than one city. `borrower_id` on a payment matches the account's borrower in 0.004% of rows. 897 borrower ids on accounts are missing from the master. | [E3] | Account to borrower comes from `accounts` only. Latest borrower version supplies geography, marked low-trust. | Geography findings carry low confidence. Borrower-level (cross-account) analysis is not possible. |
| 13 | **Promise status is not backed by money.** | Sum successful payments between promise and due date + 3 days [fact_ptp] | `verified_kept` computed from payments. | Reported kept rate about 50%; verified 3%. `KEPT` promises are followed by any payment 5.1% of the time, `BROKEN` 4.1%. |
| 14 | **Status history unreliable.** 50% of rows recorded before the event; latest history status equals the account status 14% of the time (chance for seven statuses). | [H2] | Not used for exclusions. | Accounts marked `WRITEOFF`, `CLOSED` or `PAID` are worked and pay exactly like `ACTIVE` ones [G4]. |
| 15 | **Campaign definitions inconsistent.** Each of 5 names carries all 5 target definitions; 19% of calls and targeting rows fall inside the campaign's dates; recommended channel matches the campaign channel 20% of the time. | [H1] | Campaign kept as a label only. No payment is attributed to a campaign. | Campaign-level performance cannot be measured. |
| 16 | **Vendor master stale.** 60% of calls run through vendors marked `INACTIVE`. | [D5] | Vendor status ignored; vendor id kept. | Vendor master cannot drive routing decisions. |
| 17 | **Missing values.** 1,827 calls without agent, 2,400 attempts without vendor, 455 accounts without borrower, 368 payments without reference, 250 visits without schedule. | Null counts | Kept, labelled `UNKNOWN` or flagged. | Under 2.1% of any table. |
| 18 | **Late and out-of-window events.** 52 calls dated 29 Dec 2025 or after 8 Aug 2026. | Min and max per table | Excluded (rule E1). | Negligible. |

## 3. Checks that came back clean

- **Portfolio mix change:** none. No account opened after November 2025; vintages look alike [F1]; first-activity curve is smooth with no late spike [F2]; worked-account mix is flat [F3].
- **Denominator manipulation:** none. Non-payers are targeted the next month at 18.55%, payers at 18.68% [G3]. Populations follow the calendar only [G1].
- **Disposition or vendor code switch-over:** none. All versions are present in equal shares every month [D3].

## 4. What the data does not contain

| Asked for in the brief | Status |
|---|---|
| 12 months of history | 7.3 months (1 Jan to 8 Aug 2026) |
| Client | No column |
| Language | No column |
| Human, predictive, IVR and agentic voice | Not distinguishable; all are rows in `calls` |
| Cost of any channel | Absent. `golden.assumed_unit_costs` holds placeholders |
| History of DPD and outstanding balance | `accounts` is one snapshot |
| Date of the targeting strategy change | Absent. All four strategy versions run all year |

## 5. Decisions and assumptions

| Topic | Decision |
|---|---|
| Source of truth: money | `payments`, status `SUCCESS`, one row per `payment_id`. Not the `PAID` disposition, not the `PAID` field-visit outcome, not account status. |
| Source of truth: account to borrower | `accounts.borrower_id`. |
| Source of truth: who an agent is | `agent_id` as used in fact tables. |
| Reporting timezone | Asia/Kolkata. |
| Window | 1 Jan to 8 Aug 2026. August is partial and excluded from month comparisons. |
| Denominator for rates | The full book of 30,000 accounts, so that no account can drop out silently. |
| Payment attribution | None in the golden layer. `last_touch_channel_7d` is descriptive. |
| Historical overwrites | Latest version kept for dimensions; version counts retained so trust can be judged. |
