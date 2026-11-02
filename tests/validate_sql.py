#!/usr/bin/env python3
"""Parse-validation for all BigQuery SQL in this repo (sqlglot, bigquery
dialect), plus a plan-mode smoke test of the loader.

No GCP account is needed or used: this proves the SQL is syntactically
valid BigQuery Standard SQL. It does not prove the queries return correct
results — that requires running them against a real project (the loader's
--dry-run mode validates the MERGE against the live catalog, which is the
strongest check short of execution).

    pip install sqlglot
    python3 loader/load_payments.py            # generate the sample CSV
    python3 tests/validate_sql.py
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    import sqlglot

    failures = 0
    files = sorted(ROOT.glob("sql/**/*.sql"))
    for path in files:
        text = path.read_text()
        try:
            statements = [s for s in sqlglot.parse(text, read="bigquery") if s]
            print(f"  parse ok   {path.relative_to(ROOT)}: {len(statements)} statements")
        except Exception as exc:
            failures += 1
            print(f"  PARSE FAIL {path.relative_to(ROOT)}: {exc}")

    # Loader plan mode must run with zero GCP configuration.
    proc = subprocess.run(
        [sys.executable, str(ROOT / "loader" / "load_payments.py"), "--plan"],
        capture_output=True, text=True)
    if proc.returncode == 0 and "MERGE" in proc.stdout:
        sample = ROOT / "sample_data" / "payments_sample.csv"
        rows = sum(1 for _ in sample.open()) - 1 if sample.exists() else 0
        print(f"  loader ok  --plan runs; sample extract generated ({rows} rows)")
    else:
        failures += 1
        print(f"  LOADER FAIL\n{proc.stdout}\n{proc.stderr}")

    print("RESULT:", "PASS" if failures == 0 else f"FAIL ({failures})")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
