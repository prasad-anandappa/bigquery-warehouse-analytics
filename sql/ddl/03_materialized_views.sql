-- ============================================================================
-- 03_materialized_views.sql — pre-aggregated serving layer.
--
-- BigQuery materialized views are maintained incrementally by the engine
-- and — the important part — queries against the base table can be
-- automatically rewritten to read the MV when the aggregation matches.
-- Use them for the aggregations every dashboard repeats (daily revenue),
-- not as a general caching hack: MVs support a restricted SQL surface
-- (single-table aggregations are the safe core), and staleness is bounded
-- by the refresh interval, which consumers must know about.
-- ============================================================================

-- Daily revenue by currency/status. Dashboards hit this shape constantly;
-- serving it from an MV means the base table scan happens once per
-- refresh, not once per dashboard viewer.
CREATE MATERIALIZED VIEW IF NOT EXISTS `<project>.payments_analytics.mv_daily_revenue`
PARTITION BY day
CLUSTER BY currency, status
OPTIONS (
    enable_refresh = TRUE,
    refresh_interval_minutes = 60,
    description = 'Daily settled/authorised totals per currency and status'
)
AS
SELECT
    DATE(paid_at)              AS day,
    currency,
    status,
    COUNT(*)                   AS payment_count,
    SUM(amount)                AS total_amount,
    COUNTIF(status = 'settled') AS settled_count,
    SUM(IF(status = 'settled', amount, 0)) AS settled_amount
FROM `<project>.payments_analytics.payments_curated`
GROUP BY day, currency, status;

-- Customer lifetime summary per *current* dimension version — the join
-- shape analysts ask for most. (A regular view: it joins two tables,
-- which is outside the portable MV feature set, and its inputs change
-- slowly enough that a view's pay-per-query cost is acceptable.)
CREATE OR REPLACE VIEW `<project>.payments_analytics.v_customer_lifetime` AS
SELECT
    c.customer_id,
    c.segment,
    c.country_code,
    COUNT(p.payment_id)                          AS payment_count,
    SUM(IF(p.status = 'settled', p.amount, 0))   AS lifetime_settled,
    MIN(p.paid_at)                               AS first_payment_at,
    MAX(p.paid_at)                               AS last_payment_at
FROM `<project>.payments_analytics.dim_customers` AS c
LEFT JOIN `<project>.payments_analytics.payments_curated` AS p
    ON p.customer_id = c.customer_id
    AND p.paid_at >= c.effective_from
    AND (c.effective_to IS NULL OR p.paid_at < c.effective_to)  -- as-was join
GROUP BY c.customer_id, c.segment, c.country_code;
