"""Run the SQL pipeline end to end:  raw CSVs -> staging -> clean -> golden -> metrics.

Usage:  python src/run_pipeline.py            (from the repo root)
Output: collections.duckdb  +  data/golden/*.parquet|csv
"""
import pathlib, sys, time
import duckdb

ROOT = pathlib.Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
DB = ROOT / "collections.duckdb"
STEPS = ["01_staging.sql", "02_clean.sql", "03_golden.sql", "04_metrics.sql"]


def main():
    if DB.exists():
        DB.unlink()                      # full rebuild => fully reproducible
    con = duckdb.connect(str(DB))
    for step in STEPS:
        t = time.time()
        sql = (ROOT / "sql" / step).read_text().replace("${RAW_DIR}", RAW.as_posix())
        con.execute(sql)
        print(f"{step:<20} ok  {time.time()-t:5.1f}s")
    out = ROOT / "data" / "golden"
    out.mkdir(parents=True, exist_ok=True)
    for (t,) in con.execute("select table_name from information_schema.tables where table_schema='golden'").fetchall():
        con.execute(f"COPY golden.{t} TO '{(out / (t + '.parquet')).as_posix()}' (FORMAT PARQUET)")
    for t in ["audit_cleaning", "metrics_monthly"]:
        con.execute(f"COPY golden.{t} TO '{(out / (t + '.csv')).as_posix()}' (HEADER)")
    print(con.execute("select source_table, raw_rows, rejected_rows, corrected_or_flagged_rows, golden_rows from golden.audit_cleaning").df().to_string(index=False))
    con.close()


if __name__ == "__main__":
    sys.exit(main())
