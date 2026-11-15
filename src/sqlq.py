"""Tiny helper: load '-- name: xyz' blocks from the sql/ folder and run them."""
import pathlib, re

SQL_DIR = pathlib.Path(__file__).resolve().parents[1] / "sql"


def load(files=("05_forensics.sql", "06_analysis.sql")):
    out = {}
    for f in files:
        text = (SQL_DIR / f).read_text()
        for block in re.split(r"^-- name:\s*", text, flags=re.M)[1:]:
            name, body = block.split("\n", 1)
            out[name.strip()] = body.strip()
    return out


def q(con, name, **params):
    sql = load()[name]
    for k, v in params.items():
        sql = sql.replace("${" + k + "}", str(v))
    return con.execute(sql).df()
