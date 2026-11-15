"""Generates notebooks/analysis.ipynb from plain cells, so the notebook is diff-able and reproducible.
Run:  python src/build_notebook.py && jupyter nbconvert --to notebook --execute --inplace notebooks/analysis.ipynb
"""
import pathlib
import nbformat as nbf

cells = []
def md(s): cells.append(nbf.v4.new_markdown_cell(s.strip("\n")))
def code(s): cells.append(nbf.v4.new_code_cell(s.strip("\n")))

md(r"""
# Collections analytics - did recovery really improve 11% month-on-month?

**How to read this notebook.** Every section has the same shape: *the question -> why we ask it -> the query -> what the result means*.
All heavy lifting is SQL in `sql/` (run by `src/run_pipeline.py`); this notebook only reads the golden layer and reasons about it.

**Evidence labels used throughout** (the brief asks for them):

| Label | Meaning |
|---|---|
| **FACT** | A direct count from the data. Anyone re-running the query gets the same number. |
| **STRONG EVIDENCE** | A conclusion that survives several independent checks. |
| **CORRELATION** | Two things move together; we have not shown one causes the other. |
| **HYPOTHESIS** | A plausible explanation the data cannot confirm. |

**Limits of the data, stated up front (FACT).** The brief says "approximately 12 months"; the files cover **1 Jan - 8 Aug 2026 (7.3 months)**.
There is **no client column, no language column, no cost data, and no flag that separates human / predictive / IVR / agentic-voice calls**.
The accounts table is a single snapshot (no history of DPD or balance). Those questions cannot be answered from these files and we say so rather than guess.
""")

code(r"""
import sys, json, pathlib, warnings
import numpy as np, pandas as pd, duckdb
import matplotlib.pyplot as plt
from scipy import stats
import statsmodels.formula.api as smf
warnings.filterwarnings("ignore")
ROOT = pathlib.Path.cwd() if (pathlib.Path.cwd() / "sql").exists() else pathlib.Path.cwd().parent
sys.path.insert(0, str(ROOT / "src"))
from sqlq import q, load
con = duckdb.connect(str(ROOT / "collections.duckdb"))          # built by src/run_pipeline.py
con.execute("CREATE OR REPLACE TEMP MACRO to_ist(ts, tz) AS ts + (CASE tz WHEN 'UTC' THEN 330 WHEN 'Asia/Dubai' THEN 90 ELSE 0 END) * INTERVAL 1 MINUTE")
pd.set_option("display.width", 220); pd.set_option("display.max_columns", 40); pd.set_option("display.float_format", lambda v: f"{v:,.3f}")
BLUE, ORANGE, INK, MUTED, GRID = "#2a78d6", "#eb6834", "#0b0b0b", "#52514e", "#e6e5e0"
plt.rcParams.update({"figure.facecolor": "#fcfcfb", "axes.facecolor": "#fcfcfb", "axes.edgecolor": GRID, "axes.spines.top": False,
                     "axes.spines.right": False, "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
                     "text.color": INK, "axes.labelcolor": MUTED, "xtick.color": MUTED, "ytick.color": MUTED, "font.size": 10})
KEY = {}     # every number quoted in the memo / dashboard is written here and saved at the end
rng = np.random.default_rng(42)
""")

md(r"""
---
## Part 1 - The golden dataset: Raw -> Rejected / Corrected -> Golden

**Why first?** Every later number depends on which rows we count. So before any analysis we fix the rules and measure what each rule does.

The table below is produced by `sql/03_golden.sql` (`golden.audit_cleaning`).
""")
code(r"""
audit = con.execute("select * from golden.audit_cleaning").df()
audit
""")
md(r"""
**Reading it.**
* *Rejected* rows are removed (duplicates, superseded versions). *Corrected / flagged* rows are kept but repaired or marked.
* `agents`: 29,000 of 30,000 rows are older versions of the same 1,000 agent ids. `borrowers`: 19,585 of 30,600 likewise.
* `payments`: only 500 rows are removed. That is deliberate - see check A below for why we did **not** remove the 7,218 payments that share a reference.

The decisions (source of truth, entity resolution, timestamps, exclusions, assumptions) are written out in `docs/data_quality_report.md`.
""")

md(r"""
---
## Part 2 - Data forensics (checks A to G)

For each check: what would the problem look like if it existed, then look for exactly that.

### A. Duplicate payments - is ingestion inflating recovery?
""")
code(r"""
display(q(con, "A2_duplicate_types"))
a1 = q(con, "A1_duplicate_payment_inflation"); display(a1)
display(q(con, "A3_is_reference_reuse_a_retry")); display(q(con, "A4_true_retry_candidates"))
a5 = q(con, "A5_status_definition_impact"); display(a5)
KEY["dup_inflation_pct_avg"] = float(a1.loc[a1.month_label < "2026-08", "inflation_pct"].mean())
KEY["all_status_inflation_pct"] = float(100 * (a5.amount_cr.sum() / a5.loc[a5.payment_status == "SUCCESS", "amount_cr"].iloc[0] - 1))
""")
md(r"""
**What this shows.**
* **FACT** - 500 payment ids appear twice (486 identical copies, 14 where one copy lost its reference). Counting raw rows inflates recovery by **about 2% every month**.
  Because the inflation is roughly the same every month it lifts the *level*, not the *trend*. It cannot explain an 11% month-on-month jump.
* **FACT** - 3,407 references are shared by 7,218 payments. In 4,252 shared-reference pairs, **zero** are on the same account and **zero** have the same amount; the median gap is 65 days.
  A retry is the same borrower paying the same amount minutes apart. These are not retries - the reference field is simply not unique. **Decision: keep them, flag them.**
* **FACT** - there are no "same account, same amount, within 72 hours" pairs at all.
* **FACT** - only 70% of payment value is `SUCCESS`. A report that sums every row regardless of status overstates recovery by ~43%.

**A trap worth showing.** If we had "cleaned" by keeping the first payment per reference, we would have removed more and more money as the year went on
(a later month has more earlier payments to collide with) and manufactured a decline that does not exist:
""")
code(r"""q(con, "A6_reference_dedup_sensitivity")""")

md(r"""
### B. Attribution errors - are payments credited to the wrong campaign / interaction?

**Idea.** If contacts cause payments, payments should be *preceded* by a contact more often than they are *followed* by one.
A contact that happens **after** a payment cannot have caused it, so the "after" column is the rate coincidence alone produces. This is a placebo test.
""")
code(r"""
b1 = q(con, "B1_last_touch_attribution"); display(b1); display(q(con, "B2_naive_latest_campaign_attribution"))
b3 = q(con, "B3_attribution_window_placebo"); display(b3)
fig, ax = plt.subplots(figsize=(7, 3.2))
ax.plot(b3.n_days, b3.pct_contact_before, color=BLUE, lw=2, marker="o", ms=5, label="contact BEFORE payment")
ax.plot(b3.n_days, b3.pct_contact_after_placebo, color=ORANGE, lw=2, marker="o", ms=5, label="contact AFTER payment (placebo)")
ax.set_xlabel("attribution window (days)"); ax.set_ylabel("% of payments 'attributed'"); ax.legend(frameon=False)
ax.set_title("A longer window attributes more payments - and so does pure coincidence", loc="left", fontsize=11); plt.show()
KEY["pct_recovery_no_contact_7d"] = float(b1.loc[b1.last_touch_channel_7d == "NO_CONTACT_7D", "pct"].iloc[0])
KEY["placebo"] = b3.to_dict("records")
""")
md(r"""
**What this shows.**
* **FACT** - 91% of recovered rupees arrive with **no effective contact on any channel in the previous 7 days**.
* **FACT** - a "credit the latest campaign that ever called" rule would hand 68% of payments to a campaign, yet only 20% of those payments fall inside that campaign's own start-end dates.
* **STRONG EVIDENCE** - at every window the "before" and "after" percentages are almost identical (the placebo is even slightly higher).
  So the share of recovery "attributed" to contact is what random overlap produces. Stretching the window from 7 to 60 days raises attributed recovery from 9% to 54% without any change in reality - this is **attribution-window bias**.

**Decision.** No payment is attributed to a campaign in the golden layer. `last_touch_channel_7d` is kept as a descriptive column only.

### C. Timezones - are calls in the wrong hour / day?
""")
code(r"""
display(q(con, "C1_timezone_misclassification")); display(q(con, "C2_compliance_window_raw_vs_ist")); display(q(con, "C3_payment_timezone_sensitivity"))
""")
md(r"""
* **FACT** - calls are stamped in three zones (UTC, Asia/Kolkata, Asia/Dubai), about a third each. Read as-is, **67% of calls sit in the wrong hour and 9.7% on the wrong day**; only 0.34% land in the wrong month.
* So timezone errors wreck any *calling-hour* analysis but barely move a *monthly* total. They cannot produce an 11% monthly change.
* **FACT** - after conversion, 54% of calls fall outside 08:00-19:00 IST. If real, that is a compliance problem, not an analytics one. (In this dataset call hours are spread evenly over 24h.)
* Payments carry no timezone. Worst case (they are in each account's zone) moves monthly recovery by less than 0.5%. **Assumption kept: payments are IST.**

### D. Vendor / disposition code changes
""")
code(r"""
display(q(con, "D2_ptp_code_share_by_month")); display(q(con, "D3_version_mix_by_month")); display(q(con, "D4_disposition_vs_call_status")); display(q(con, "D5_vendor_status_usage"))
""")
md(r"""
* **FACT** - two codes mean the same thing: `PTP` and `PROMISE_TO_PAY`. A report that knows only one of them shows a PTP share of ~11% instead of ~22%, i.e. **half the promises go missing**.
* **FACT** - there was **no switch-over date**: both spellings and all three disposition versions (legacy / v1 / v2) appear at about a third each in every month. So this halves the level of PTP metrics but does not create a trend.
* **FACT** - 17,868 "right-party" dispositions (PTP, PAID, REFUSED...) sit on calls whose status is BUSY / FAILED / NO_ANSWER / VOICEMAIL. You cannot get a promise from a call nobody answered. Our RPC definition requires the call to be answered.
* **FACT** - 60% of calls run through vendors marked `INACTIVE` in the vendor master. The master is stale, or the routing is.

### E. Agent identity
""")
code(r"""
display(q(con, "E1_agent_identity")); display(q(con, "E2_calls_by_agent_current_status")); display(q(con, "E3_borrower_identity"))
""")
md(r"""
* **FACT** - 30,000 agent rows describe 1,000 agent ids. Each id has on average **29.6 different employee codes, 9.5 names and 13 vendors**, and each employee code sits on ~27 agent ids.
  There is no attribute stable enough to merge or split agents on. 4,078 rows were "updated" before the agent "joined".
* **Decision** - `agent_id` is the entity (it is what every fact table uses). Team, vendor and tenure are taken from the latest version and are **low-trust**. Agent-tenure findings are labelled accordingly.
* **FACT** - the same disease affects borrowers: 8,159 of 11,015 ids have more than one city; the `borrower_id` written on a payment matches the account's borrower in 0.004% of rows. Source of truth for account->borrower is the accounts table.

### F. Portfolio mix - did the business acquire a different book?
""")
code(r"""
display(q(con, "F1_portfolio_vintage")); display(q(con, "F2_first_activity_month")); display(q(con, "F3_worked_mix_by_month"))
""")
md(r"""
* **FACT** - no account was opened after Nov 2025 and the four opening vintages look alike (DPD ~56, ~50% HIGH/NPA).
* **FACT** - accounts first appear in operations in a smooth decaying curve (19k in Jan, 6.6k in Feb, ...) - what you get when 30,000 accounts are touched at random. A purchased portfolio would show a late spike. There is none.
* **FACT** - the mix of accounts *worked* each month is flat (DPD 90+ share 26.8-27.6%). **No evidence of a portfolio shift.**

### G. Denominator manipulation - are failures disappearing?
""")
code(r"""
display(q(con, "G1_denominator_by_month")); display(q(con, "G2_targeting_status_by_month")); display(q(con, "G3_do_non_payers_drop_out")); display(q(con, "G4_terminal_status_accounts_still_in_play"))
display(q(con, "H1_campaign_definition_consistency")); display(q(con, "H2_status_history_reliability"))
""")
md(r"""
* **FACT** - targeted, worked and dialled populations all move with the number of days in the month and nothing else.
* **FACT** - accounts that did *not* pay in month m are targeted next month at the same rate (18.55%) as accounts that paid (18.68%). Nobody is being dropped for failing.
* **No evidence of denominator manipulation.** Our own metrics use the full 30,000-account book as denominator precisely so this cannot happen silently.
* Side findings (**FACT**): accounts whose snapshot status is WRITEOFF / CLOSED / PAID are worked and pay exactly like ACTIVE ones, and the latest status in the history table agrees with the account table only 14% of the time (7 statuses, so 1-in-7 = chance). Half the history rows were "recorded" before the event. **The status fields are not usable.**
* Campaigns (**FACT**): 5 names carry all 5 target definitions each; only 19% of calls and targeting rows fall inside their campaign's dates; the recommended channel matches the campaign channel 20% of the time.
""")

md(r"""
---
## Part 3a - What actually happened? Rebuilding the headline number

**The single most important table in this notebook.**
""")
code(r"""
t1 = q(con, "T1_month_on_month"); display(t1)
m = con.execute("select * from golden.metrics_monthly order by month_start").df()
full = m[m.is_full_month]
fig, axes = plt.subplots(1, 2, figsize=(11, 3.4), sharex=True)
axes[0].bar(full.month_label.str[5:], full.recovery_amount / 1e7, color=BLUE, width=0.55)
axes[0].set_title("Total recovery per month (Rs Cr) - looks like it swings +/-10%", loc="left", fontsize=10.5); axes[0].set_ylim(0, 22)
axes[1].bar(full.month_label.str[5:], full.recovery_per_day / 1e5, color=BLUE, width=0.55)
axes[1].set_title("Recovery per calendar day (Rs lakh) - flat", loc="left", fontsize=10.5); axes[1].set_ylim(0, 70)
for ax, col, k in ((axes[0], "recovery_amount", 1e7), (axes[1], "recovery_per_day", 1e5)):
    for x, v in zip(full.month_label.str[5:], full[col] / k): ax.text(x, v + 0.6 * (22 if k == 1e7 else 70) / 22 * 0.5, f"{v:.1f}", ha="center", fontsize=9, color=MUTED)
plt.tight_layout(); plt.show()
""")
md(r"""
**Reading it.**
* **FACT** - the only month-on-month move of 11% in the whole period is **February -> March: +11.0%** (raw rows and clean rows agree).
* **FACT** - February has 28 days, March has 31: **+10.7% more days**. Recovery *per day* went from Rs 60.8 lakh to Rs 60.9 lakh: **+0.3%**.
* **STRONG EVIDENCE** - the reported "+11% month-on-month" is a calendar-length artefact. The same artefact produces -9% (Jan->Feb), -7% (Mar->Apr), +5%, -5%, +7%. Recovery did not "improve"; the month got longer.
  (We are not told which months the report compared - **HYPOTHESIS**: Feb->Mar - but no pair of months shows an 11% rise on a per-day basis.)

Now put a confidence interval on it, so "flat" is a measured statement and not an impression.
""")
code(r"""
d = con.execute("select * from golden.metrics_daily order by day").df()
d["day"] = pd.to_datetime(d["day"]); d["month"] = d.day.dt.strftime("%Y-%m"); d["t"] = np.arange(len(d)); d["dow"] = d.day.dt.dayofweek

# 1) Bootstrap: resample DAYS within each month, recompute the Feb->Mar ratios 5,000 times.
feb, mar = d[d.month == "2026-02"].recovery_amount.values, d[d.month == "2026-03"].recovery_amount.values
bs_total, bs_perday = [], []
for _ in range(5000):
    f, r = rng.choice(feb, len(feb)), rng.choice(mar, len(mar))
    bs_total.append(r.sum() / f.sum() - 1); bs_perday.append(r.mean() / f.mean() - 1)
ci = lambda x: np.percentile(x, [2.5, 97.5]) * 100
print(f"Feb->Mar TOTAL   change: {100*(mar.sum()/feb.sum()-1):+.1f}%   95% CI {ci(bs_total)[0]:+.1f}% .. {ci(bs_total)[1]:+.1f}%")
print(f"Feb->Mar PER-DAY change: {100*(mar.mean()/feb.mean()-1):+.1f}%   95% CI {ci(bs_perday)[0]:+.1f}% .. {ci(bs_perday)[1]:+.1f}%")
KEY["feb_mar_total_pct"] = float(100*(mar.sum()/feb.sum()-1)); KEY["feb_mar_perday_pct"] = float(100*(mar.mean()/feb.mean()-1)); KEY["feb_mar_perday_ci"] = [float(v) for v in ci(bs_perday)]

# 2) Trend: daily recovery ~ day index + day-of-week. Slope = Rs/day change per day.
fit = smf.ols("recovery_amount ~ t + C(dow)", d).fit()
slope, lo, hi = fit.params["t"], *fit.conf_int().loc["t"]
base, span = d.recovery_amount.mean(), len(d) - 1
print(f"Trend over the {len(d)} days: {100*slope*span/base:+.1f}%  (95% CI {100*lo*span/base:+.1f}% .. {100*hi*span/base:+.1f}%),  p = {fit.pvalues['t']:.2f}")
print(f"Equivalent month-on-month growth: {100*slope*30.4/base:+.2f}% per month (95% CI {100*lo*30.4/base:+.2f}% .. {100*hi*30.4/base:+.2f}%)")
print("Day-of-week effect F-test p =", round(float(smf.ols('recovery_amount ~ C(dow)', d).fit().f_pvalue), 2))
KEY["trend_total_pct"] = float(100*slope*span/base); KEY["trend_ci"] = [float(100*lo*span/base), float(100*hi*span/base)]
KEY["trend_mom_pct"] = float(100*slope*30.4/base); KEY["trend_mom_ci"] = [float(100*lo*30.4/base), float(100*hi*30.4/base)]; KEY["trend_p"] = float(fit.pvalues["t"])

# 3) Change-point: is there ANY date where the level shifts? CUSUM statistic vs 2,000 shuffles of the same days.
x = d.recovery_amount.values; cus = lambda v: np.abs(np.cumsum(v - v.mean())).max()
obs = cus(x); perm = np.array([cus(rng.permutation(x)) for _ in range(2000)])
cp = d.day.iloc[int(np.abs(np.cumsum(x - x.mean())).argmax())].date()
print(f"Change-point test: most likely break {cp}, permutation p = {(perm >= obs).mean():.2f}  (p > 0.05 => no detectable break)")
KEY["changepoint_p"] = float((perm >= obs).mean()); KEY["changepoint_date"] = str(cp)
print("Lag-1 autocorrelation of daily recovery:", round(d.recovery_amount.autocorr(1), 2), "| coefficient of variation:", round(d.recovery_amount.std()/d.recovery_amount.mean(), 2))
""")
md(r"""
**What this shows (STRONG EVIDENCE).**
* The per-day Feb->Mar change is statistically zero; its confidence interval comfortably contains 0 and excludes anything like +11%.
* Across the whole period the fitted trend is slightly *negative* and not significant; the confidence interval for monthly growth rules out +11% a month by a wide margin.
* No change-point: there is no date at which the level of recovery shifts. **"When did performance change?" - it did not.**
* No day-of-week pattern, no autocorrelation: daily recovery behaves like independent noise around ~Rs 60 lakh a day.

## Part 3b - The KPI set, naive vs challenged definitions
""")
code(r"""
cols = ["month_label","days_observed","naive_contact_rate_calls","contact_rate_accounts","naive_rpc_rate_dispositions","rpc_rate_accounts",
        "ptp_rate_of_contacted_accounts","naive_ptp_kept_rate","verified_ptp_kept_rate","recovery_rate_of_book_30d","payer_rate",
        "recovery_per_account_in_book","recovery_per_agent_hour","assumed_cost_per_rupee_recovered"]
k = m[cols].set_index("month_label").T; display(k)
KEY["monthly"] = json.loads(m.assign(month_start=m.month_start.astype(str)).to_json(orient="records"))
KEY["ptp_kept_reported"] = float(full.naive_ptp_kept_rate.mean()*100); KEY["ptp_kept_verified"] = float(full[full.month_label < "2026-07"].verified_ptp_kept_rate.mean()*100)
""")
md(r"""
| KPI | Usual (naive) definition | Why it misleads | Our definition | Result |
|---|---|---|---|---|
| **Contact rate** | answered calls / calls dialled | Counts calls, so re-dialling the same borrower "improves" it; mixes time zones | accounts with >=1 answered call / accounts dialled in the month | ~23%, flat |
| **RPC** | "contact" dispositions / dispositioned calls | Only 32% of calls have a disposition; 80% of RPC dispositions are on unanswered calls | accounts with an **answered** call whose **final** disposition is right-party / accounts dialled | ~6% (naive says 77%) |
| **PTP rate** | PTP dispositions / calls | Misses one of the two PTP codes; call-level | accounts with a PTP / accounts effectively contacted | ~8%, flat |
| **PTP kept** | status = KEPT / (KEPT + BROKEN) | Status field is not backed by money | matured promises where successful payments in [promise, due + 3d] >= 90% of promised amount | **~3%** (reported ~49%) |
| **Recovery rate** | Rs collected in month / Rs outstanding | Month length; snapshot denominator | Rs per day x 30 / outstanding of the full book | ~1.7% per 30 days, flat |
| **Recovery / account** | Rs / accounts that paid, or / accounts worked | Denominator can be shrunk | Rs / all 30,000 accounts in the book | ~Rs 6,000 per month |
| **Recovery / agent-hour** | Rs / logged hours | Sessions in UTC vs IST; credits agents for unprompted payments | Rs / session hours (IST) - reported, but **not** read as productivity | ~Rs 16,600, flat |
| **Cost per Rs recovered** | - | No cost data exists | parametric: assumed unit costs in `golden.assumed_unit_costs` | ~2 paise per Rs (illustrative only) |
| **Channel conversion** | payments after a touch / touches | Ignores that borrowers pay anyway | 7-day payment rate after an effective contact **minus the baseline** rate | lift ~0 on every channel (next section) |

**The most misleading metric is PTP kept (FACT):** the system labels ~49% of resolved promises `KEPT`, but only ~3% are followed by enough money to cover the promise, and ~4.5% by any payment at all. Promises labelled `KEPT` are followed by a payment 5.1% of the time, promises labelled `BROKEN` 4.1% of the time - the label carries almost no information.

---
## Part 3c - Why? Testing every driver

**Method.** For each dimension, build a table of (level -> successes, failures) and run a chi-square test: *"could differences this large arise by chance if the dimension made no difference?"*
A small p-value (< 0.05) says "probably not chance". We run ~35 such tests, so by luck alone we expect 1-2 below 0.05 - which is why the last column applies the Benjamini-Hochberg correction.
""")
code(r"""
con.execute(load()["setup_call_outcomes"])
rows = []
call_dims = [("Agent","agent_id"),("Agent tenure (low-trust)","agent_tenure_band"),("Agent team (low-trust)","agent_team"),("Campaign (120 ids)","campaign_id"),
             ("Campaign name","campaign_name"),("Strategy version","strategy_version"),("Campaign channel","campaign_channel"),("Telephony vendor (15 ids)","vendor_id"),
             ("Telephony vendor name","vendor_name"),("Calling time (IST band)","hour_band_ist"),("Calling hour (IST)","call_hour_ist"),("Attempts on the call","LEAST(n_attempt_rows,4)"),("Direction","direction")]
for label, dim in call_dims:
    t = q(con, "D_call_dimension", DIM=dim)
    for out, name in (("answered","call answered"),("paid_7d","paid within 7d of call")):
        chi, p, dof, _ = stats.chi2_contingency(np.array([t[out], t.calls - t[out]]))
        rows.append((label, name, len(t), t[out+"_pct"].min(), t[out+"_pct"].max(), p))
acct_dims = [("Portfolio mix: loan type","a.loan_type"),("DPD bucket","a.dpd_bucket"),("Borrower segment (risk)","a.risk_segment"),("Geography: state (low-trust)","a.state"),
             ("Geography: city (low-trust)","a.city"),("Account status snapshot","a.snapshot_status"),("Channels used in month","LEAST(m.n_channels,4)"),
             ("Attempt frequency: calls in month","LEAST(m.n_calls,4)"),("Targeted in month","(m.n_target_rows>0)"),("Effectively contacted in month","(m.n_effective_contacts>0)"),("Gave a PTP in month","(m.n_ptp>0)")]
for label, dim in acct_dims:
    t = q(con, "D_account_dimension", DIM=dim)
    chi, p, dof, _ = stats.chi2_contingency(np.array([t.paying, t.account_months - t.paying]))
    rows.append((label, "account paid in month", len(t), t.payer_rate_pct.min(), t.payer_rate_pct.max(), p))
drv = pd.DataFrame(rows, columns=["dimension","outcome","levels","lowest_level_pct","highest_level_pct","p_value"])
o = drv.p_value.rank(method="first").astype(int); n = len(drv)
drv["p_adjusted_BH"] = (drv.p_value * n / o).clip(upper=1).iloc[np.argsort(o.values)[::-1]].cummin().reindex(drv.index)
drv.loc[drv.levels > 30, ["lowest_level_pct","highest_level_pct"]] = np.nan      # min/max over 100s of tiny groups is just noise
display(drv.style.format({"lowest_level_pct":"{:.2f}","highest_level_pct":"{:.2f}","p_value":"{:.3f}","p_adjusted_BH":"{:.3f}"}, na_rep="-"))
print(f"{n} tests | raw p < 0.05: {(drv.p_value < .05).sum()} (expected by chance: {n*0.05:.1f}) | after correction: {(drv.p_adjusted_BH < .05).sum()}")
KEY["n_driver_tests"] = int(n); KEY["n_sig_raw"] = int((drv.p_value < .05).sum()); KEY["n_sig_adj"] = int((drv.p_adjusted_BH < .05).sum())
KEY["drivers"] = json.loads(drv.to_json(orient="records"))
""")
md(r"""
**What this shows (STRONG EVIDENCE).** No dimension the brief asks about separates payers from non-payers, or answered calls from unanswered ones.
* DPD: payer rate is 7.6%-7.9% from "current" all the way to 90+ days past due. In a real book this gradient is steep. Here it is absent.
* Agents: the spread of results across 1,000 agents is exactly what chance produces (p = 0.63 / 0.25) - there are no measurably better or worse agents.
* The one raw p < 0.05 (vendor name, p = 0.02) is what you expect from 37 tests and disappears after correction - **CORRELATION at best, most likely noise.**
* **Client** and **language**: not in the data. Cannot be investigated.

### Channel conversion against the baseline
""")
code(r"""
ch = q(con, "CH_channel_conversion"); ch["rate_pct"] = 100 * ch.paid / ch.n
b = ch[ch.channel.str.startswith("BASELINE")].iloc[0]
def lift(r):
    p1, p0 = r.paid / r.n, b.paid / b.n
    se = np.sqrt(p1 * (1 - p1) / r.n + p0 * (1 - p0) / b.n)
    return pd.Series({"lift_pp": 100 * (p1 - p0), "ci_low_pp": 100 * (p1 - p0 - 1.96 * se), "ci_high_pp": 100 * (p1 - p0 + 1.96 * se), "relative_lift_pct": 100 * (p1 / p0 - 1)})
ch = pd.concat([ch, ch.apply(lift, axis=1)], axis=1); display(ch)
c2 = ch[~ch.channel.str.startswith("BASELINE")]
fig, ax = plt.subplots(figsize=(7, 2.6))
ax.errorbar(c2.lift_pp, c2.channel, xerr=[c2.lift_pp - c2.ci_low_pp, c2.ci_high_pp - c2.lift_pp], fmt="o", color=BLUE, ms=7, lw=2, capsize=3)
ax.axvline(0, color=INK, lw=1); ax.set_xlabel("extra 7-day payment rate vs baseline (percentage points, 95% CI)")
ax.set_title(f"No channel beats the baseline of {b.paid/b.n*100:.2f}% (any account, any week)", loc="left", fontsize=11); ax.grid(axis="y", visible=False); plt.show()
KEY["channel_lift"] = json.loads(ch.to_json(orient="records")); KEY["baseline_7d_pct"] = float(100 * b.paid / b.n)
""")
md(r"""
**Reading it.** After an effective contact, 1.6%-1.9% of accounts pay within 7 days. But **1.84% of *all* accounts pay in *any* 7-day window**, contacted or not.
Voice, SMS and WhatsApp all have confidence intervals that include zero. Field visits sit slightly *below* baseline (the interval just excludes zero; with four comparisons and repeat visits to the same accounts this is weak evidence - **CORRELATION**, and in the wrong direction for an investment case).
"WhatsApp converts at 1.8%" is true and meaningless - that is what doing nothing converts at.

---
## Part 3d - The seven statistical traps

### Mix effect & Simpson's paradox
**Mix effect** = the total changes because the *share* of each segment changed, not because any segment performed differently.
**Simpson's paradox** = the total moves one way while every segment moves the other. We decompose the Feb -> Mar change in payer rate by DPD bucket.
""")
code(r"""
t = q(con, "D_account_dimension_by_month", DIM="a.dpd_bucket"); t["rate"] = t.paying / t.accounts
def decompose(a_lbl, b_lbl, base="worked"):
    A, B = (t[t.month_label == x].set_index("level") for x in (a_lbl, b_lbl))
    wA, wB = A[base] / A[base].sum(), B[base] / B[base].sum()
    mix = ((wB - wA) * A.rate).sum(); rate = (wA * (B.rate - A.rate)).sum(); inter = ((wB - wA) * (B.rate - A.rate)).sum()
    return pd.Series({"total_change_pp": 100*(mix+rate+inter), "mix_effect_pp": 100*mix, "rate_effect_pp": 100*rate, "interaction_pp": 100*inter})
dec = pd.DataFrame({"Feb -> Mar": decompose("2026-02","2026-03"), "Jan -> Jul": decompose("2026-01","2026-07")}).T; display(dec)
piv = t.pivot(index="level", columns="month_label", values="rate") * 100
piv.loc["ALL"] = (t.groupby("month_label").paying.sum() / t.groupby("month_label").accounts.sum() * 100); display(piv.round(2))
chg = piv["2026-07"] - piv["2026-01"]; print("Jan->Jul change by segment (pp):", chg.round(2).to_dict())
KEY["mix_effect_feb_mar_pp"] = float(dec.loc["Feb -> Mar","mix_effect_pp"])
""")
md(r"""
* **FACT** - the mix effect is ~0.00 percentage points: the composition of worked accounts did not change.
* Segments move up and down by small amounts with no common direction and the total sits in the middle of them - **no Simpson's paradox.**

### Cohort effects, selection bias, survivorship bias
""")
code(r"""
display(q(con, "COH_vintage_cohorts").pivot(index="vintage", columns="month_label", values="payer_rate_pct"))
sel = q(con, "SEL_selection_bias"); display(sel)
display(q(con, "SURV_survivorship")); display(q(con, "AF_attempt_frequency"))
p_sel = stats.chi2_contingency(np.array([sel.paying, sel.account_months - sel.paying]))[1]; print("targeted vs not targeted, p =", round(p_sel, 3))
KEY["targeted_rate"] = float(sel.payer_rate_pct.iloc[1]); KEY["untargeted_rate"] = float(sel.payer_rate_pct.iloc[0]); KEY["targeted_p"] = float(p_sel)
""")
md(r"""
* **Cohorts** - the four opening vintages have the same payer rate and the same flat path. No vintage is carrying the total.
* **Selection bias** - targeted accounts look identical to untargeted ones on DPD, risk and balance (so targeting is not selecting on anything observable), and pay at 7.88% vs 7.70% (p = 0.24, not significant). **CORRELATION, not distinguishable from zero.**
* **Survivorship** - if the population were being purified (good payers staying, bad ones leaving), the payer rate among "never paid before" accounts would fall away from the full-book rate over time. The two columns stay together.
* **Attempt frequency** - dialling an account 0, 1, 2, 3 or 4+ times in a month makes no difference to whether it pays.
* **Attribution-window bias** - shown in check B. **Time-series effects** - shown in Part 3a.

---
## Part 4 - Counterfactual: "what if we had not changed the targeting strategy?"

**The honest starting point.** The data has a `strategy_version` on each campaign (legacy, v1, v2, v3) but all four are in use, in the same proportions, in every month - **there is no visible switch date**. The brief says to *assume* a mid-year change, so we assume a cut-over on **2026-04-20** (the midpoint of the data) and treat v2/v3 as the "new" strategy.

**Design: difference-in-differences (DiD).**

| Element | Choice |
|---|---|
| Unit | one targeting decision (a row of `daily_targeting`) |
| Outcome | did the account make a successful payment in the 30 days after `target_date`? |
| Treatment group | accounts targeted by NEW-strategy campaigns (v2 / v3) |
| Control group | accounts targeted by OLD-strategy campaigns (legacy / v1) in the same period |
| Estimate | (NEW after - NEW before) - (OLD after - OLD before) |
| Why DiD | anything that hits everyone in the second half (season, economy, month length) cancels out in the subtraction |
| Key assumption | *parallel trends*: without the change, NEW and OLD would have moved together. Checked on the pre-period below. |
| Confounders | DPD, risk, loan type, balance - added as controls; channel mix; the same account can be targeted by both arms (handled by clustering standard errors on account) |
| Limitations | no real switch date; campaigns are not randomly assigned; 30-day outcome windows overlap; targets after 9 Jul are dropped (not enough follow-up) |
""")
code(r"""
cf = q(con, "CF_targeting_rows", CUTOVER="2026-04-20")
cf["new"] = (cf.arm == "NEW").astype(int); cf["post"] = (cf.period == "POST").astype(int); cf["paid"] = cf.paid_30d.astype(int)
display(cf.groupby(["arm","period"]).agg(targets=("paid","size"), paid_30d_pct=("paid", lambda s: 100*s.mean()), rs_per_target=("amount_30d","mean")).round(2))
fit_cf = smf.ols("paid ~ new*post + C(dpd_bucket) + C(risk_segment) + C(loan_type)", cf).fit(cov_type="cluster", cov_kwds={"groups": cf.account_id})
eff, (lo, hi) = fit_cf.params["new:post"], fit_cf.conf_int().loc["new:post"]
print(f"DiD effect of the new strategy on 30-day payment rate: {100*eff:+.2f} pp  (95% CI {100*lo:+.2f} .. {100*hi:+.2f}),  p = {fit_cf.pvalues['new:post']:.2f}")
# parallel-trends / placebo check: pretend the cut-over was 1 March, using only PRE data
pre = cf[cf.post == 0].copy(); pre["fake_post"] = (pd.to_datetime(pre.target_date) >= "2026-03-01").astype(int)
pl = smf.ols("paid ~ new*fake_post", pre).fit(cov_type="cluster", cov_kwds={"groups": pre.account_id})
print(f"Placebo (fake cut-over 1 Mar, pre-period only): {100*pl.params['new:fake_post']:+.2f} pp, p = {pl.pvalues['new:fake_post']:.2f}  -> should be ~0 if trends are parallel")
# translate into rupees
n_treated = int(((cf.new == 1) & (cf.post == 1)).sum()); ticket = float(con.execute("select avg(amount) from golden.fact_payment where is_recovery").fetchone()[0])
actual = float(cf.loc[(cf.new == 1) & (cf.post == 1), "amount_30d"].sum())
to_cr = lambda e: e * n_treated * ticket / 1e7
print(f"NEW-strategy targets after cut-over: {n_treated:,}. Their actual 30-day recovery: Rs {actual/1e7:.2f} Cr")
print(f"Estimated recovery caused by the change: Rs {to_cr(eff):+.2f} Cr (95% CI {to_cr(lo):+.2f} .. {to_cr(hi):+.2f})")
print(f"=> Counterfactual (no change): Rs {actual/1e7 - to_cr(eff):.2f} Cr, plausible range Rs {actual/1e7 - to_cr(hi):.2f} .. {actual/1e7 - to_cr(lo):.2f} Cr")
KEY.update(did_pp=float(100*eff), did_ci=[float(100*lo), float(100*hi)], did_p=float(fit_cf.pvalues["new:post"]), did_cr=float(to_cr(eff)), did_cr_ci=[float(to_cr(lo)), float(to_cr(hi))],
           cf_actual_cr=actual/1e7, placebo_pp=float(100*pl.params["new:fake_post"]), placebo_p=float(pl.pvalues["new:fake_post"]), avg_ticket=ticket)
""")
md(r"""
**Reading it.** The estimated effect of the new strategy is a fraction of a percentage point with a confidence interval that spans zero: **recovery would have looked about the same without the change** - roughly Rs 4.5 Cr against the Rs 4.8 Cr actually collected from these targets, with a plausible range of Rs 3.9-5.2 Cr that includes the actual figure. The placebo is also ~0, so the parallel-trends assumption is not contradicted.

**What would make this a real answer:** a recorded switch date and, better, a **randomised hold-out** - keep 10% of eligible accounts on the old strategy each day. Then the comparison needs no assumptions at all.

---
## Part 5 - Where should the Rs 10 Cr go?

First, can account features predict who pays? If not, there is nothing for a targeting model - or any segment-specific investment - to exploit *in this data*.
""")
code(r"""
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import cross_val_score
X = con.execute('''select a.account_id, a.dpd, a.outstanding_amount, a.principal_amount, a.loan_type, a.risk_segment, a.state,
                          max(m.paid_flag::int) filter (m.month_start between date '2026-04-01' and date '2026-07-01') as y,
                          sum(m.n_payments) filter (m.month_start < date '2026-04-01') as prior_payments,
                          sum(m.n_effective_contacts) filter (m.month_start < date '2026-04-01') as prior_contacts
                   from golden.dim_account a join golden.fact_account_month m using (account_id) group by all''').df()
F = pd.get_dummies(X.drop(columns=["account_id","y"]), drop_first=True).astype(float); F = (F - F.mean()) / F.std()
auc = cross_val_score(LogisticRegression(max_iter=500), F, X.y, cv=5, scoring="roc_auc")
print(f"Predict 'pays in Apr-Jul' from account features + Jan-Mar behaviour: AUC = {auc.mean():.3f} (+/- {auc.std():.3f}).  0.5 = coin toss.")
KEY["auc"] = float(auc.mean())
""")
code(r"""
clean_total = float(full.recovery_amount.sum()); days = int(full.days_observed.sum())
annual = clean_total / days * 365 / 1e7
print(f"Clean recovery Jan-Jul: Rs {clean_total/1e7:.1f} Cr over {days} days = Rs {clean_total/days/1e5:.1f} lakh/day = Rs {annual:.0f} Cr a year (run-rate)")
INVEST = 10.0
print(f"Break-even on Rs {INVEST:.0f} Cr: +{100*INVEST/annual:.1f}% recovery sustained for 12 months, or +{100*INVEST/annual/2:.1f}% for 24 months")
sc = pd.DataFrame({"scenario": ["Downside (what the data shows)", "Break-even (24 months)", "Base ASSUMPTION", "Upside ASSUMPTION"], "uplift_pct": [0.0, 100*INVEST/annual/2, 3.0, 6.0]})
sc["incremental_cr_per_year"] = sc.uplift_pct / 100 * annual
sc["roi_12m_pct"] = 100 * (sc.incremental_cr_per_year - INVEST) / INVEST; sc["roi_24m_pct"] = 100 * (2 * sc.incremental_cr_per_year - INVEST) / INVEST
sc["payback_months"] = np.where(sc.incremental_cr_per_year > 0, INVEST / sc.incremental_cr_per_year.replace(0, np.nan) * 12, np.nan); display(sc.round(1))
# what the data allows for each lever: the UPPER end of the 95% CI of its measured lift
p0 = float(full.payer_rate.mean())
def mde(n_per_arm, p=p0): return 2.8 * np.sqrt(2 * p * (1 - p) / n_per_arm) / p * 100
print(f"\nExperiment sizing (monthly payer rate {100*p0:.2f}%; 80% power, 5% significance):")
for months in (2, 3, 6): print(f"  50/50 split of 30,000 accounts for {months} months -> smallest detectable lift = {mde(15000*months):.1f}% relative")
KEY.update(clean_total_cr=clean_total/1e7, annual_runrate_cr=annual, breakeven_12m_pct=100*INVEST/annual, breakeven_24m_pct=100*INVEST/annual/2, scenarios=json.loads(sc.to_json(orient="records")),
           mde_3m=float(mde(45000)), mde_6m=float(mde(90000)), payer_rate_pct=100*p0, per_day_lakh=clean_total/days/1e5)
""")
md(r"""
### The recommendation, and how sure we are

**What the data can and cannot support (STRONG EVIDENCE):**

| Option | Evidence in this data | Verdict |
|---|---|---|
| 1 Telephony infrastructure | Answer rate is 19-21% on every vendor (p = 0.45); answered calls are followed by payment at the baseline rate | no measurable return |
| 2 More agents | No agent differs from chance; dialling more often does not raise payment; 91% of money arrives with no contact in the prior 7 days | no measurable return |
| 3 AI voice automation | Voice sub-types (human / IVR / agentic) are not identifiable in the data | cannot be evaluated |
| 4 Better borrower targeting | Targeted accounts pay 7.88% vs 7.70% (p = 0.24); features do not predict payment (AUC ~0.5) | no measurable return *yet* - but it is the option that builds the measurement |
| 5 WhatsApp / digital | 7-day payment rate after a read/reply equals baseline | no measurable return |
| 6 Field operations | 7-day payment rate after a visit is slightly below baseline; highest unit cost | no measurable return |

**So the first answer is the one the brief allows: the data is insufficient to justify committing Rs 10 Cr to any single option.** On this evidence the expected incremental recovery of all six is ~Rs 0, i.e. an expected loss of the full amount.

**If one must be named: option 4, Better borrower targeting - released in two stages.**
* **Stage 1 (~Rs 1 Cr, about 6 months on a book this size):** fix the measurement that this analysis found broken (payment <-> interaction linkage, one campaign definition, a real strategy switch log, agent and vendor masters) and run a **randomised hold-out**: every day a random 50% of eligible accounts get the targeting engine's treatment, 50% get business-as-usual.
* **Stage 2 (~Rs 9 Cr):** released only if the hold-out shows a statistically significant lift of at least **+4.6%** (the 12-month break-even). The sizing above shows a 50/50 test on 30,000 accounts needs ~6 months to see an effect that small; a larger live book shortens this proportionally.
* **Why this one:** it is the only option whose first rupee buys *information* about all six; it is reversible; and its downside is capped at the stage-1 spend instead of Rs 10 Cr.
* The 3% and 6% scenarios above are **assumptions used to set the pass mark, not forecasts**. Nothing in this data supports them.
""")
code(r"""
out = ROOT / "data" / "golden" / "key_numbers.json"; out.write_text(json.dumps(KEY, indent=1, default=str)); print("saved", out)
con.close()
""")

nb = nbf.v4.new_notebook(cells=cells, metadata={"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}})
out = pathlib.Path(__file__).resolve().parents[1] / "notebooks" / "analysis.ipynb"
nbf.write(nb, out); print("wrote", out)
