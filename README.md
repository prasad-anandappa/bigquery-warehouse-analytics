# bigquery-warehouse-analytics

[![CI](https://github.com/prasad-anandappa/bigquery-warehouse-analytics/actions/workflows/ci.yml/badge.svg)](https://github.com/prasad-anandappa/bigquery-warehouse-analytics/actions/workflows/ci.yml)

A BigQuery payments warehouse built around the platform's actual economics:
**you pay for bytes scanned, so physical design *is* cost design.**
Partitioned + clustered fact tables, an incremental MERGE pipeline with
hash-diff change detection, an SCD Type 2 customer dimension, materialized
views for the serving layer, and INFORMATION_SCHEMA cost monitoring as a
standing ops practice.

## Layout

```
sql/ddl/        dataset, partitioned/clustered tables, SCD2 dimension, MVs
sql/pipelines/  01 incremental MERGE (raw -> curated) + watermark advance
                02 SCD Type 2 customer merge (hash diffing, close/open)
sql/analytics/  window analytics: MoM growth, cohort retention, funnel
sql/monitoring/ INFORMATION_SCHEMA cost & health queries
loader/         load_payments.py — plan / dry-run / run modes
tests/          sqlglot parse validation (bigquery dialect) + loader smoke
```

## Run it

There is no sandbox shortcut for BigQuery — you need a GCP project. The
repo is honest about that; everything is staged so the first run is cheap
and reversible:

```bash
export BQ_PROJECT=my-project
gcloud auth application-default login

# 1. See exactly what would happen (no client calls):
python3 loader/load_payments.py --plan

# 2. Create the schema (substitute your project for <project> first):
bq query --use_legacy_sql=false < sql/ddl/01_dataset_and_tables.sql
bq query --use_legacy_sql=false < sql/ddl/02_customer_dim_scd2.sql
bq query --use_legacy_sql=false < sql/ddl/03_materialized_views.sql

# 3. Validate the MERGE against the real catalog without processing data:
pip install google-cloud-bigquery
python3 loader/load_payments.py --dry-run     # reports bytes it would process

# 4. Load the sample extract and merge it:
python3 loader/load_payments.py --run
```

## Design decisions & trade-offs

**Partitioning + clustering, with the filter enforced.** `payments_curated`
is partitioned by `DATE(paid_at)` and clustered by `(currency, status)`,
and `require_partition_filter = TRUE` turns a missing date filter into an
error instead of a full-table bill. Clustering order follows filter
frequency (currency first — most queries are per-currency), not alphabet.

**Incremental MERGE, three properties engineered in:**
- *Idempotent* — change detection is a SHA-256 over the business columns;
  a re-delivered unchanged row produces no update, so re-runs are free of
  downstream churn.
- *Late-data safe* — matching is by key + hash, and the watermark only
  bounds what the loader *fetches*. A watermark-only design (load
  `WHERE updated_at > watermark`, insert blindly) silently drops late
  corrections; this one doesn't.
- *Dedup before merge* — the source side collapses to the newest version
  per key (`QUALIFY ROW_NUMBER()`) because MERGE raises on multiple
  source matches, and CDC feeds *will* deliver duplicates.

**SCD Type 2 with hash diffing.** Tracked-attribute changes close the
current `dim_customers` row and open a new version, in two steps — a
single MERGE can't insert the replacement for a row it just updated in
the shape this pattern needs, and the two-step form is auditable. Hash
comparison replaces column-by-column OR chains: shorter, and a newly
tracked attribute joins exactly two hash inputs instead of N conditions.
Absent-from-snapshot customers are *not* closed — absence usually means a
truncated extract, not a deletion; deletes belong in a tombstone feed.

**Materialized views where they fit, views where they don't.**
`mv_daily_revenue` is single-table aggregation — squarely in MV territory,
with automatic query rewrite as the prize. The customer-lifetime query
joins a dimension with an as-was (effective-dated) predicate, outside the
portable MV feature set, so it's a plain view and pays per query — stated,
not hidden.

## Cost model — partitioning & clustering, quantified (ESTIMATES)

Worked example, assumptions stated so you can re-derive every number:
`payments_curated` holds one year of payments; the columns a daily-revenue
query touches total **100 GiB** logical; on-demand list price
**$6.25 / TiB**; queries filter to **one day** and, in the clustered case,
**one of four currencies**.

| Query shape | Bytes scanned (est.) | Cost per run (est.) | Why |
|---|---|---|---|
| No partitioning — full table | 100 GiB | ~$0.61 | Columnar scan still reads every row's columns |
| Partition filter only (1 day) | ~0.27 GiB (100/365) | ~$0.002 | Partition pruning skips 364 partitions |
| Partition + cluster (1 day, 1 currency) | ~0.07 GiB | ~$0.0004 (10 MiB minimums apply) | Cluster blocks for other currencies skipped within the partition |

At dashboard scale the absolute dollars are small either way; at
100× data (10 TiB fact, same query) the unpartitioned run is ~$61 *per
execution* and the partitioned+clustered run is still under a cent. That
asymmetry — cost grows with the table vs. cost grows with the question —
is the entire argument for the physical design, and why
`sql/monitoring/cost_queries.sql` (top-20 expensive jobs, cache hit rate,
partition health) is part of the project rather than an afterthought.

## Failure modes & scaling notes

- **MERGE multiple-match errors** mean the staging dedup was bypassed —
  the load path is the only writer to staging for a reason.
- **Watermark never advances on failure**: the advance is the last
  statement of the merge script; a failed merge stops the script first.
- **MV staleness** is bounded by `refresh_interval_minutes = 60`; consumers
  needing fresher data query the base table and pay for it knowingly.
- **Small-file / small-table regime**: below ~1 GiB, minimum billing and
  slot overheads dominate and this design's benefits are mostly
  organisational (contracts, lineage) rather than monetary — said plainly
  so the design isn't oversold.
- **Partition count limits** (4,000/table) cap daily partitioning at ~11
  years of history; monthly partitioning is the fallback for longer
  retention, chosen per table, not globally.

## Verification

What runs here (and in CI): every SQL file parse-validated with sqlglot's
BigQuery dialect, and the loader exercised in `--plan` mode end-to-end
(sample extract generation included). What deliberately does *not* run
without your project: actual execution — the loader's `--dry-run` mode is
provided precisely as the strongest pre-flight check (catalog-validated,
byte-counted) before any real run. No metrics in this README come from a
live project; the cost table is a worked model from stated assumptions.

## What I learned / next steps

- BigQuery rewards designs that make the *cheap query the easy query*:
  `require_partition_filter` is a guardrail with more long-term value
  than any single optimisation.
- Next: scheduled queries + Dataform-style dependency management for the
  pipeline SQL, BI Engine reservation analysis for the dashboard
  workload, and row-level security policies on the curated table.

## License

MIT — see [LICENSE](LICENSE).
