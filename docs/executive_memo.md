# Executive memo: is recovery up 11% month-on-month?

**To:** Leadership team  **From:** Analytics  **Data:** 17 source tables, 1 Jan to 8 Aug 2026

## 1. What happened?

**Recovery did not improve. It has been flat since January at about Rs 59.8 lakh a day (roughly Rs 218 Cr a year).**

The only month-on-month rise of 11% in the data is February to March (+11.0%). February has 28 days and March has 31, which is 10.7% more days. Measured per calendar day, the change is **+0.3%** (95% range −5.9% to +7.0%). The same calendar effect produces −9% in February, −7% in April and +7% in July.

Over the full 220 days the trend is −0.4% a month (range −1.2% to +0.5%), which rules out anything near +11% a month. No date shows a shift in level.

| | Reported style | Verified |
|---|---|---|
| Feb to Mar recovery | +11.0% | +0.3% per day |
| Recovery, Jan to Jul | Rs 129.3 Cr (raw rows) | Rs 126.8 Cr (unique successful payments) |
| Promises kept | 50% | 3% |
| Right-party contact rate | 77% | 6% |

## 2. Why did it happen?

Nothing operational changed, and nothing in the portfolio changed. The apparent improvement comes from how the number is calculated.

- **Month length** explains the 11%.
- **Duplicate payment rows** inflate recovery by about 2% in every month, which raises the level and leaves the trend untouched.
- **Portfolio mix** did not move: no accounts were opened after November 2025, and the share of accounts 90+ days past due among those worked stays between 26.8% and 27.6%.
- **No driver stands out.** Of 37 tests across DPD, loan type, risk segment, geography, agent, agent tenure, campaign, channel, telephony vendor, calling hour and attempt frequency, one was significant before correcting for multiple tests and none after. One or two is what chance alone produces.
- **Outreach is not visibly moving payments.** 91% of recovered rupees arrive with no effective contact on any channel in the previous 7 days. After a contact, 1.6% to 1.9% of accounts pay within a week; 1.84% of all accounts pay in any week regardless.

Three metrics are actively misleading. *Promises kept* is reported at about 50%, while only 3% of promises are followed by enough money to cover them. *Right-party contact* counts promise codes logged on calls nobody answered. *Campaign attribution* credits 68% of payments to a campaign, yet only a fifth of those payments fall inside that campaign's dates.

## 3. How confident are we?

| Conclusion | Confidence |
|---|---|
| The +11% is a calendar effect; per-day recovery is flat | **Strong evidence.** Three independent tests agree. |
| Duplicates inflate recovery by about 2% | **Fact.** Direct count. |
| No portfolio shift, no denominator manipulation | **Strong evidence.** |
| Promise and contact metrics are overstated | **Fact.** |
| No channel, agent, vendor or segment performs differently | **Strong evidence** for this dataset. A real effect smaller than about 0.2 percentage points on a channel could still be hidden. |
| Targeted accounts pay slightly more (7.88% against 7.70%) | **Correlation**, not significant (p = 0.24). |

Limits: the files cover 7.3 months, not 12. There is no client, language or cost field, and human, IVR and AI voice calls cannot be told apart. Agent, borrower and account-status records are unreliable (one agent ID carries 30 employee codes on average), so agent tenure and geography findings carry less weight.

## 4. What should we do?

**Do not commit the Rs 10 Cr to any of the six options yet.** On this evidence each has an expected incremental recovery of about nil. AI voice automation cannot be assessed at all, because the data does not identify it.

**If one option must be named, it is better borrower targeting, released in two stages:**

1. **Stage 1, about Rs 1 Cr, roughly six months.** Repair measurement (link payments to interactions, one definition per campaign, a log of strategy changes, clean agent and vendor masters). Run a randomised hold-out: each day half of eligible accounts get the targeting engine, half get business as usual.
2. **Stage 2, about Rs 9 Cr.** Release only if the hold-out shows a statistically significant lift of at least 4.6%.

This is the one option where the first rupee tells us whether the other nine are worth spending, on this option or any of the other five. Separately, at no cost: report recovery per day, count only unique successful payments, and retire the promise-kept and campaign-attribution figures until they are rebuilt.

## 5. Expected financial impact

| Scenario | Lift in recovery | Extra recovery a year | Payback | 24-month ROI |
|---|---|---|---|---|
| What the data shows | 0% | Rs 0 | never | −100% (stage 1 only: −Rs 1 Cr) |
| Break-even over 24 months | 2.3% | Rs 5.0 Cr | 24 months | 0% |
| Break-even over 12 months | 4.6% | Rs 10.0 Cr | 12 months | +100% |
| Assumed base case | 3% | Rs 6.6 Cr | 18 months | +31% |
| Assumed upside | 6% | Rs 13.1 Cr | 9 months | +162% |

The 3% and 6% rows are assumptions used to set the pass mark for stage 2. They are not forecasts, and nothing in this data supports them. Key assumptions: the Rs 218 Cr run-rate holds; lift is measured on gross recovery (if the business earns only a commission on recovery, break-even rises in proportion); any lift persists for the payback period. Staging caps the downside at about Rs 1 Cr.

A counterfactual estimate of the mid-year targeting change gives the same answer: +0.6 percentage points on the 30-day payment rate (range −0.5 to +1.6), or Rs +0.35 Cr (range −0.3 to +1.0 Cr) on Rs 4.8 Cr collected from those accounts. Recovery would have looked the same without it.
