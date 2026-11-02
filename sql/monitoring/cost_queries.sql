-- ============================================================================
-- cost_queries.sql — warehouse cost & health monitoring via
-- INFORMATION_SCHEMA. In BigQuery, cost observability is a first-class
-- engineering duty: one unfiltered query against a partitioned fact table
-- can cost more than a month of careful ones. These are the queries on
-- the weekly ops review.
--
-- Replace <project> and the region qualifier (region-us) as needed.
-- ============================================================================

-- 1. Daily spend: bytes billed and estimated on-demand cost per day.
--    On-demand list price used here: $6.25 per TiB processed — verify the
--    current price for your billing account; the query's job is the trend
--    and the outliers, not accounting-grade invoicing.
SELECT
    DATE(creation_time) AS day,
    COUNT(*) AS jobs,
    ROUND(SUM(total_bytes_billed) / POW(1024, 4), 3) AS tib_billed,
    ROUND(SUM(total_bytes_billed) / POW(1024, 4) * 6.25, 2) AS est_cost_usd,
    ROUND(SUM(total_slot_ms) / 1000 / 60, 1) AS slot_minutes
FROM `<project>.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT`
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND job_type = 'QUERY'
  AND state = 'DONE'
GROUP BY day
ORDER BY day;

-- 2. The 20 most expensive queries of the last 7 days, with the user and
--    the labels — this is the list you act on (missing partition filter is
--    the usual finding; destination table + bytes processed tells you).
SELECT
    job_id,
    user_email,
    DATE(creation_time) AS day,
    ROUND(total_bytes_billed / POW(1024, 3), 2) AS gib_billed,
    ROUND(total_bytes_processed / POW(1024, 3), 2) AS gib_processed,
    -- billed >> processed usually means a small result was EXPENSIVE to
    -- compute (huge shuffle/join) or caching was bypassed
    LEFT(query, 200) AS query_preview
FROM `<project>.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT`
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  AND job_type = 'QUERY' AND state = 'DONE'
ORDER BY total_bytes_billed DESC
LIMIT 20;

-- 3. Cache hit rate: cached queries bill 0 bytes. A falling hit rate on
--    dashboard workloads usually means someone set use_query_cache=false
--    or started parameterising queries with volatile literals.
SELECT
    DATE(creation_time) AS day,
    COUNTIF(cache_hit) AS cached_jobs,
    COUNT(*) AS total_jobs,
    ROUND(100.0 * COUNTIF(cache_hit) / COUNT(*), 1) AS cache_hit_pct
FROM `<project>.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT`
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND job_type = 'QUERY' AND state = 'DONE'
GROUP BY day
ORDER BY day;

-- 4. Storage footprint per table — where the bytes live, split by active
--    vs long-term storage (long-term pricing kicks in at 90 untouched days
--    per partition, which partitioning aligns with naturally).
SELECT
    table_name,
    ROUND(active_logical_bytes / POW(1024, 3), 2) AS active_gib,
    ROUND(longterm_logical_bytes / POW(1024, 3), 2) AS longterm_gib,
    row_count AS rows_total
FROM `<project>.payments_analytics.INFORMATION_SCHEMA.TABLE_STORAGE`
ORDER BY active_gib DESC;

-- 5. Partition health for payments_curated: partition count, sizes, and
--    the newest partition — a stalled max partition date is the earliest
--    signal that the load pipeline stopped, days before a dashboard user
--    complains.
SELECT
    partition_id,
    total_rows,
    ROUND(total_logical_bytes / POW(1024, 2), 1) AS mib,
    last_modified_time
FROM `<project>.payments_analytics.INFORMATION_SCHEMA.PARTITIONS`
WHERE table_name = 'payments_curated' AND partition_id IS NOT NULL
ORDER BY partition_id DESC
LIMIT 40;
