# Walkthrough: how this assignment was built, step by step

This is the plain-language guide to the repo. Each step says what was done, why, and where the code is. Read it next to `notebooks/analysis.ipynb`.

## The idea in one paragraph

A business says "recovery is up 11% month-on-month". An analyst's job is to ask three things in order: *Is the number counted correctly?* (data quality), *Is it compared fairly?* (definitions), and *If something moved, what caused it?* (statistics). Most of the work is the first two. Here they turn out to be the whole story.

## Step 0. Read the brief and list what it asks for

Four questions (what happened, why, is 11% real, where to invest), five parts (golden dataset, forensics, statistics, counterfactual, production design) and seven deliverables. The repo has one file or folder for each, listed in `README.md`.

## Step 1. Profile every table before trusting any of them

**What:** for each of the 17 CSVs, count rows, count distinct IDs, count blanks, find the earliest and latest date, and list the values of every category column.

**Why:** the first number in each row tells you what is broken. Examples from this data:

| What the profile showed | What it means |
|---|---|
| `payments`: 25,500 rows, 25,000 distinct `payment_id` | 500 duplicate rows |
| `agents`: 30,000 rows, 1,000 distinct `agent_id` | the table stores many versions of each agent |
| `calls.timezone` has three values | times cannot be compared until converted |
| dates run 1 Jan to 8 Aug 2026 | 7.3 months, not the 12 the brief mentions |
| no `client` or `language` column anywhere | two of the brief's dimensions cannot be analysed |

**Lesson:** say what the data cannot answer. Reviewers reward that more than a guess.

## Step 2. Build the pipeline in layers

**Where:** `sql/01_staging.sql` to `sql/04_metrics.sql`, run by `src/run_pipeline.py`.

| Layer | Rule | Why a separate layer |
|---|---|---|
| **Staging** | Load each CSV with fixed column types. Change nothing. | You can always prove the row count matches the file. |
| **Clean** | Fix one table at a time: remove duplicates, convert time zones, merge duplicate codes, add flags. | Each fix is visible and countable. |
| **Golden** | Join clean tables into analysis tables with a stated grain ("one row per payment"). | Everyone computes metrics from the same tables. |
| **Metrics** | One row per month with every KPI. | A KPI is defined once, in SQL. |

The cleaning rules and the reasoning behind each:

1. **Payments: one row per `payment_id`.** A payment can only happen once, so two rows with the same ID are a loading error. Keep the copy that still has its reference.
2. **Payments: do not deduplicate on `payment_reference`.** 7,218 payments share a reference, which looks like a duplicate problem. Checking shows none share an account or an amount and they are 65 days apart on average, so they are different payments with a non-unique reference. Removing them would delete Rs 18.6 Cr of real money. *Test a suspicion before acting on it.*
3. **Only `SUCCESS` is recovery.** Failed, pending and reversed payments are not money in the bank.
4. **Convert call times to IST.** UTC is 5h30 behind IST and Dubai is 1h30 behind. Without this, a 10 am call logged in UTC looks like a 4:30 am call.
5. **Merge `PTP` and `PROMISE_TO_PAY`.** Same meaning, two spellings.
6. **Agents and borrowers: keep the latest version, and admit the attributes are unreliable.** One agent ID has 30 employee codes on average. No rule can fix that, so the limitation is stated.
7. **Never trust a label that money can check.** A promise marked `KEPT` is checked against actual payments (`golden.fact_ptp`).
8. **Keep every account in every month** (`golden.fact_account_month`). If an account is only present when something happened, failures vanish from the denominator.

The table `golden.audit_cleaning` records raw rows, rejected rows, corrected rows and golden rows for every source. That is the "Raw → Rejected/Corrected → Golden" the brief asks for.

## Step 3. Forensics: look for each problem deliberately

**Where:** `sql/05_forensics.sql`, checks A to G, each a named query.

The method is the same every time: *"If this problem existed, what would I see?"* Then look for exactly that.

| Check | What you would see if it existed | Result |
|---|---|---|
| A. Duplicate payments | more rows than payment IDs | Yes, about 2% every month. Constant, so it cannot create growth. |
| B. Wrong attribution | payments credited to contacts that could not have caused them | Yes. Contacts are as common *after* a payment as before it. |
| C. Timezone errors | hours shift when converted | Yes. 67% of calls in the wrong hour. Only 0.3% in the wrong month. |
| D. Code changes | one code fading out as another fades in | No switch. Both PTP codes are used all year. |
| E. Agent identity | many identifiers per person | Yes, severe. |
| F. New portfolio | a block of accounts appearing mid-year | No. |
| G. Shrinking denominator | non-payers targeted less the next month | No. 18.55% against 18.68%. |

The check in B is worth understanding. A contact that happens after a payment cannot have caused it. So "how often is a payment followed by a contact" measures pure coincidence. If "preceded by a contact" is no higher than that, outreach is not visibly causing payments. This is called a **placebo test**.

## Step 4. Find the 11%

**Where:** query `T1_month_on_month` in `sql/06_analysis.sql`; notebook Part 3a.

List recovery by month and compute each month-on-month change. Exactly one equals 11%: February to March. Then ask what differs between those months. February has 28 days and March has 31, which is 10.7% more days. Divide by days: Rs 60.8 lakh a day against Rs 60.9 lakh a day, a change of +0.3%.

**Lesson:** always compare like with like. Totals over periods of different length are not comparable.

Three tests then confirm "flat" is a measured result:

| Test | Plain meaning | Result |
|---|---|---|
| Bootstrap | Reshuffle the days thousands of times to see how much the Feb to Mar change could vary by luck | per-day change between −5.9% and +7.0%, so zero is well inside |
| Trend regression | Fit a straight line through 220 days of recovery | slope of −0.4% a month, not different from zero (p = 0.42) |
| Change-point (CUSUM) | Search for any date where the level jumps | none (p = 0.32) |

A **p-value** is the chance of seeing a difference this large if nothing real were going on. Below 0.05 is the usual bar for "probably real".

## Step 5. Challenge each KPI

**Where:** `sql/04_metrics.sql`; notebook Part 3b; definitions in `docs/production_design.md`.

For each metric ask: *what is the numerator, what is the denominator, and how could either be gamed or broken?*

- **Count accounts, not calls.** Redialling the same person ten times raises a call-based contact rate without reaching anyone new.
- **Use the whole book as denominator.** A denominator of "accounts that responded" can be shrunk to raise any rate.
- **Verify labels with money.** Promise-kept went from 50% reported to 3% verified.
- **Compare to a baseline.** "1.8% pay within a week of a WhatsApp" means nothing until you know 1.84% pay in any week anyway.

## Step 6. Test every possible driver

**Where:** notebook Part 3c; queries `D_call_dimension` and `D_account_dimension`.

For each dimension in the brief (DPD, loan type, risk segment, geography, agent, tenure, campaign, channel, vendor, calling hour, attempt frequency) build a table of how many paid and how many did not at each level, then run a **chi-square test**, which asks whether the differences between levels are bigger than chance would give.

37 tests were run. One had p below 0.05. With 37 tests you expect about two by luck, so a correction for multiple testing (Benjamini-Hochberg) is applied, and after it none remain. **Running many tests and reporting only the winners is the commonest way analysts fool themselves.**

Then the seven traps the brief names, each with one query:

| Trap | Plain meaning | Check |
|---|---|---|
| Mix effect | the total moves because the blend of segments changed | decomposition: 0.00 points |
| Simpson's paradox | the total and every segment move in opposite directions | segment table: not present |
| Cohort effect | one vintage of accounts drives the total | four vintages, same path |
| Selection bias | the accounts chosen for treatment were different to begin with | targeted and untargeted accounts look the same |
| Survivorship bias | failures leave, so the remainder looks better | rate among never-paid accounts tracks the total |
| Attribution-window bias | a longer window credits more payments to outreach | 9% at 7 days, 54% at 60 days, same as the placebo |
| Time-series effects | trend, seasonality, month length | Step 4 |

## Step 7. The counterfactual

**Where:** notebook Part 4; query `CF_targeting_rows`.

The question is "what would have happened without the targeting change?" You cannot observe that, so you estimate it with **difference-in-differences**: take the change in the group that got the new strategy, subtract the change in a group that did not. Anything that affected both groups cancels out.

| Piece | Choice |
|---|---|
| Treatment group | accounts targeted by campaigns on strategy v2 or v3 |
| Control group | accounts targeted by legacy or v1 campaigns |
| Before and after | split at 20 April 2026, an assumed date, because the data records none |
| Outcome | paid within 30 days of being targeted |
| Result | +0.6 points (range −0.5 to +1.6), not different from zero |

A placebo run with a fake switch date in the pre-period also gives about zero, which supports the method. The write-up states the weaknesses openly: no real switch date and no random assignment.

## Step 8. The investment recommendation

**Where:** notebook Part 5; memo sections 4 and 5.

Every option was checked against the data and none shows a measurable return. A model predicting who pays scores 0.50, which is a coin toss. The brief allows the answer "the data is insufficient", so that is the first answer.

Because the brief also says to recommend one, the choice is **better borrower targeting, in two stages**: a small first stage that fixes measurement and runs a randomised test, and the large second stage only if the test passes. The numbers:

- Run-rate: Rs 218 Cr a year.
- Break-even: Rs 10 Cr ÷ Rs 218 Cr = 4.6% more recovery for a year.
- Test size: a 50/50 split of 30,000 accounts needs about six months to detect 4.6%.

The 3% and 6% scenarios in the memo are labelled as assumptions, because the data does not support any uplift figure.

## Step 9. Package for the reader

| Reader | File | Rule followed |
|---|---|---|
| CEO, 60 seconds | `dashboard/dashboard.html` | headline states the conclusion; four numbers; two charts that show the illusion and the reality side by side; one decision box |
| Leadership, 5 minutes | `docs/executive_memo.pdf` | five questions from the brief as headings, two pages |
| Reviewer | `notebooks/analysis.ipynb` | question, reason, query, interpretation for every step |
| Engineer | `docs/production_design.md` | layers, keys, contracts, late data, checks, monitoring |

## How to talk about this in an interview

1. "I profiled first and found the data covers 7 months and lacks client and language, so I said so."
2. "I built staging, clean, golden and metrics layers and measured what every cleaning rule removed."
3. "The 11% is February to March. March has 10.7% more days. Per day the change is 0.3%."
4. "I did not deduplicate on payment reference, because the shared references are different accounts and amounts. Doing so would have invented a decline."
5. "I tested 37 driver cuts, corrected for multiple testing, and found none. I showed contacts are as frequent after payments as before, so last-touch attribution is measuring coincidence."
6. "On this evidence no investment option has a measurable return, so I recommended a staged test with a stated pass mark instead of committing Rs 10 Cr."

One caution to raise yourself: the dataset is synthetic and behaves like random noise, so "no effect anywhere" is the correct reading of *this* data. In a real collections book DPD and contact normally matter a great deal, and the same pipeline would show it.
