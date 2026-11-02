-- ============================================================================
-- 01_dataset_and_tables.sql — BigQuery warehouse: payments analytics
--
-- Physical design is the cost model in BigQuery: you pay for bytes scanned,
-- so partitioning (scan less) and clustering (skip blocks within the scan)
-- are not "optimisations", they are the pricing contract.
--
-- Conventions:
--   <project> is a placeholder — substitute your GCP project id.
--   Raw tables keep source fidelity; curated tables are query-ready.
--   require_partition_filter = TRUE makes an unfiltered query against a
--   partitioned table a hard error instead of an expensive accident.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS `<project>.payments_analytics`
OPTIONS (
    description = 'Payments warehouse: raw, curated, dimensions, marts',
    default_table_expiration_days = NULL,          -- facts don't expire
    location = 'US'
);

-- ------------------------------------------------------------ raw payments
-- Landing zone: exactly what the source delivered, plus ingestion metadata.
-- Partitioned by event date; clustered by the two columns nearly every
-- query filters or groups on (currency, status).
CREATE TABLE IF NOT EXISTS `<project>.payments_analytics.payments_raw`
(
    payment_id    STRING    NOT NULL,
    order_id      STRING    NOT NULL,
    customer_id   STRING    NOT NULL,
    amount        NUMERIC   NOT NULL,   -- NUMERIC (decimal), never FLOAT64, for money
    currency      STRING    NOT NULL,
    status        STRING    NOT NULL,   -- authorised | settled | failed | voided
    paid_at       TIMESTAMP NOT NULL,
    updated_at    TIMESTAMP NOT NULL,   -- source-side change timestamp (CDC)
    _ingested_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    _batch_id     STRING    NOT NULL    -- load batch, for lineage/debugging
)
PARTITION BY DATE(paid_at)
CLUSTER BY currency, status
OPTIONS (
    description = 'Raw payments as delivered by the source system',
    require_partition_filter = TRUE,
    partition_expiration_days = NULL
);

-- -------------------------------------------------------- curated payments
-- One row per payment_id (the current version), maintained by the
-- incremental MERGE in pipelines/01. _row_hash drives change detection:
-- recomputing and comparing a SHA-256 over the business columns is how the
-- MERGE knows a row actually changed vs. was merely re-delivered.
CREATE TABLE IF NOT EXISTS `<project>.payments_analytics.payments_curated`
(
    payment_id    STRING    NOT NULL,
    order_id      STRING    NOT NULL,
    customer_id   STRING    NOT NULL,
    amount        NUMERIC   NOT NULL,
    currency      STRING    NOT NULL,
    status        STRING    NOT NULL,
    paid_at       TIMESTAMP NOT NULL,
    updated_at    TIMESTAMP NOT NULL,
    _row_hash     BYTES     NOT NULL,
    _loaded_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
PARTITION BY DATE(paid_at)
CLUSTER BY currency, status
OPTIONS (
    description = 'Current-state payments, one row per payment_id',
    require_partition_filter = TRUE
);

-- ------------------------------------------------------------- staging area
-- Short-lived landing table for one MERGE run; expiration is a feature:
-- staging that lives forever becomes an unowned second copy of the data.
CREATE TABLE IF NOT EXISTS `<project>.payments_analytics.payments_staging`
(
    payment_id    STRING,
    order_id      STRING,
    customer_id   STRING,
    amount        NUMERIC,
    currency      STRING,
    status        STRING,
    paid_at       TIMESTAMP,
    updated_at    TIMESTAMP
)
OPTIONS (
    description = 'Per-run staging for the incremental MERGE; expires in 7 days',
    expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
);

-- ------------------------------------------------------ pipeline state
-- Watermarks live in a table, not in a scheduler variable: they survive
-- scheduler restarts, are inspectable in SQL, and are part of the audit
-- trail of what was loaded when.
CREATE TABLE IF NOT EXISTS `<project>.payments_analytics.etl_state`
(
    pipeline_name     STRING    NOT NULL,
    watermark         TIMESTAMP NOT NULL,  -- high-water mark of updated_at loaded
    last_run_at       TIMESTAMP NOT NULL,
    last_batch_id     STRING,
    rows_merged       INT64,
    PRIMARY KEY (pipeline_name) NOT ENFORCED
)
OPTIONS (description = 'Per-pipeline load watermarks and run audit');
