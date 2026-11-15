# Collections analytics assignment: is recovery really up 11% month-on-month?

**Answer: no.** Recovery has been flat at about Rs 59.8 lakh a day since January. The only +11% month-on-month move in the data is February to March, and March is 10.7% longer than February. Per calendar day the change is +0.3% (95% range −5.9% to +7.0%).

**Live dashboard:** https://sarthak14-r.github.io/collections-analytics-assignment/dashboard/dashboard.html

## Deliverables

| # | Deliverable | Where |
|---|---|---|
| 1 | SQL repository | `sql/01_staging.sql` → `02_clean.sql` → `03_golden.sql` → `04_metrics.sql`, plus `05_forensics.sql` and `06_analysis.sql` |
| 2 | Analysis notebook (executed, with reasoning) | `notebooks/analysis.ipynb` |
| 3 | Golden dataset and the pipeline that builds it | `data/golden/*.parquet`, `src/run_pipeline.py` |
| 4 | Data quality report | `docs/data_quality_report.md` |
| 5 | Executive dashboard (one screen) | `dashboard/dashboard.html` (open in a browser) |
| 6 | Executive memo (2 pages) | `docs/executive_memo.pdf`, source in `docs/executive_memo.md` |
| 7 | Architecture diagram and production design | `docs/architecture.svg`, `docs/production_design.md` |
| | Step-by-step explanation of the approach | `docs/WALKTHROUGH.md` |

## Reproduce everything

```bash
pip install -r requirements.txt
# put the 17 raw CSVs in data/raw/ (calls.csv, payments.csv, ...)
make            # or run the three steps below
python src/run_pipeline.py          # raw -> staging -> clean -> golden -> metrics (about 5 seconds)
python src/build_notebook.py && (cd notebooks && jupyter nbconvert --to notebook --execute --inplace analysis.ipynb)
python src/build_dashboard.py       # dashboard reads data/golden/key_numbers.json written by the notebook
```

The engine is DuckDB, so there is no database to install. The pipeline deletes and rebuilds `collections.duckdb` on every run, and the bootstrap uses a fixed seed, so results repeat on every run (to floating-point rounding).

## The four questions

1. **What happened?** Nothing changed. No trend (−0.4% a month, range −1.2% to +0.5%), no break-point, no day-of-week pattern.
2. **Why?** The 11% is month length. Duplicate rows add about 2% to every month. Portfolio mix, DPD, geography, agent, tenure, campaign, channel, vendor, calling time, attempt frequency and segment show no effect: 37 tests, 1 significant before correction, 0 after. Client and language are not in the data.
3. **Is the 11% real?** No. Like-for-like it is +0.3%. Several other reported metrics are also wrong: promises kept (50% reported, 3% verified), right-party contact (77% against 6%), campaign attribution.
4. **Where to invest Rs 10 Cr?** The data cannot justify any of the six options. If one must be named: better borrower targeting, staged. About Rs 1 Cr on measurement and a randomised hold-out, and the remaining Rs 9 Cr only if the test shows a lift of at least 4.6% (the 12-month break-even).

## Known limits

- The files cover 1 Jan to 8 Aug 2026 (7.3 months), not 12.
- No client, language or cost columns; voice sub-types (human, IVR, agentic) cannot be separated.
- `accounts` is a single snapshot, so recovery rate uses a fixed balance.
- Unit costs in `golden.assumed_unit_costs` are placeholders.
- Raw CSVs are not committed (`.gitignore`); the golden parquet files are.
