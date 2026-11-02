#!/usr/bin/env python3
"""Loader for the payments warehouse: CSV extract -> staging -> MERGE.

Design: the loader owns *movement* (generate/land the extract into
payments_staging); the SQL in sql/pipelines owns *semantics* (the MERGE).
Keeping them apart means the merge logic is reviewable SQL, not string
templates inside Python.

Modes:
  --plan     Print the execution plan and the exact SQL that would run.
             No GCP client needed. This is the default.
  --dry-run  Submit the MERGE as a dry-run query job and report the bytes
             it would process. Requires google-cloud-bigquery and
             credentials (ADC). A dry run validates the SQL against the
             real catalog — the strongest pre-flight check available.
  --run      Execute for real: load the CSV into staging, then run the
             MERGE script. Requires the same credentials.

Without a GCP project configured (env BQ_PROJECT unset), --dry-run and
--run stop with instructions instead of failing obscurely.
"""

from __future__ import annotations

import argparse
import csv
import os
import random
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MERGE_SQL = ROOT / "sql" / "pipelines" / "01_incremental_merge_payments.sql"
PROJECT_PLACEHOLDER = "<project>"


def generate_sample_csv(path: Path, *, rows: int = 500, seed: int = 42) -> Path:
    """Deterministic sample extract, including re-delivered rows so the
    MERGE's dedup (QUALIFY ROW_NUMBER) has something real to do."""
    rng = random.Random(seed)
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    fieldnames = ["payment_id", "order_id", "customer_id", "amount",
                  "currency", "status", "paid_at", "updated_at"]
    with path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for i in range(1, rows + 1):
            paid = start + timedelta(days=rng.randint(0, 180),
                                     hours=rng.randint(0, 23))
            row = {
                "payment_id": f"pay_{i:05d}",
                "order_id": f"ord_{i:05d}",
                "customer_id": f"cust_{rng.randint(1, 120):04d}",
                "amount": f"{rng.uniform(5, 900):.2f}",
                "currency": rng.choice(["USD", "USD", "EUR", "GBP"]),
                "status": rng.choice(["settled", "settled", "authorised", "failed"]),
                "paid_at": paid.strftime("%Y-%m-%d %H:%M:%S"),
                "updated_at": paid.strftime("%Y-%m-%d %H:%M:%S"),
            }
            writer.writerow(row)
            if i % 97 == 0:  # re-delivery with a status correction
                corrected = dict(row, status="settled")
                corrected["updated_at"] = (
                    paid + timedelta(hours=2)).strftime("%Y-%m-%d %H:%M:%S")
                writer.writerow(corrected)
    return path


def render_merge_sql(project: str) -> str:
    return MERGE_SQL.read_text().replace(PROJECT_PLACEHOLDER, project)


def plan(project: str, csv_path: Path) -> None:
    print(f"project:        {project}")
    print(f"extract:        {csv_path}")
    print("steps:")
    print("  1. load CSV -> payments_staging (WRITE_TRUNCATE, this run only)")
    print("  2. execute sql/pipelines/01_incremental_merge_payments.sql")
    print("     (dedup by QUALIFY, hash-diff MERGE, watermark advance)")
    print("  3. staging expires automatically after 7 days (table option)")
    print("\n--- MERGE SQL (project-substituted) ---\n")
    print(render_merge_sql(project))


def get_client(project: str):
    try:
        from google.cloud import bigquery
    except ImportError:
        print("google-cloud-bigquery is not installed.\n"
              "Install it with: pip install google-cloud-bigquery",
              file=sys.stderr)
        raise SystemExit(2)
    return bigquery.Client(project=project)


def dry_run(project: str) -> None:
    from google.cloud import bigquery

    client = get_client(project)
    job = client.query(
        render_merge_sql(project),
        job_config=bigquery.QueryJobConfig(dry_run=True, use_query_cache=False),
    )
    mib = job.total_bytes_processed / (1024 * 1024)
    print(f"dry run OK — MERGE would process {mib:.1f} MiB "
          f"(~${job.total_bytes_processed / 1024**4 * 6.25:.4f} at "
          "on-demand list price)")


def run(project: str, csv_path: Path) -> None:
    from google.cloud import bigquery

    client = get_client(project)
    staging = f"{project}.payments_analytics.payments_staging"
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        skip_leading_rows=1,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        autodetect=False,
        schema=[
            bigquery.SchemaField("payment_id", "STRING"),
            bigquery.SchemaField("order_id", "STRING"),
            bigquery.SchemaField("customer_id", "STRING"),
            bigquery.SchemaField("amount", "NUMERIC"),
            bigquery.SchemaField("currency", "STRING"),
            bigquery.SchemaField("status", "STRING"),
            bigquery.SchemaField("paid_at", "TIMESTAMP"),
            bigquery.SchemaField("updated_at", "TIMESTAMP"),
        ],
    )
    with csv_path.open("rb") as fh:
        load_job = client.load_table_from_file(fh, staging, job_config=job_config)
    load_job.result()
    print(f"staging loaded: {load_job.output_rows} rows")
    client.query(render_merge_sql(project)).result()
    print("MERGE complete; watermark advanced in etl_state")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--plan", action="store_true", help="(default)")
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--run", action="store_true")
    parser.add_argument("--csv", type=Path, default=None,
                        help="extract CSV; a sample is generated if omitted")
    args = parser.parse_args(argv)

    project = os.environ.get("BQ_PROJECT", "")
    csv_path = args.csv or generate_sample_csv(
        ROOT / "sample_data" / "payments_sample.csv")
    if args.plan or not (args.dry_run or args.run):
        plan(project or PROJECT_PLACEHOLDER, csv_path)
        return 0
    if not project:
        print("BQ_PROJECT is not set. Set it to your GCP project id and "
              "configure Application Default Credentials:\n"
              "  export BQ_PROJECT=my-project\n"
              "  gcloud auth application-default login",
              file=sys.stderr)
        return 2
    if args.dry_run:
        dry_run(project)
    else:
        run(project, csv_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
