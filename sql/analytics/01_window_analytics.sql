-- ============================================================================
-- 01_window_analytics.sql — revenue analytics over payments_curated.
-- Every query carries a partition filter on paid_at (required by the
-- table options) — cost discipline is part of the query, not a hope.
-- ============================================================================

-- Monthly revenue with running total and month-over-month growth.
WITH monthly AS (
    SELECT
        currency,
        DATE_TRUNC(DATE(paid_at), MONTH) AS month,
        SUM(IF(status = 'settled', amount, 0)) AS settled_revenue,
        COUNTIF(status = 'settled') AS settled_count
    FROM `<project>.payments_analytics.payments_curated`
    WHERE DATE(paid_at) BETWEEN DATE '2026-01-01' AND DATE '2026-12-31'
    GROUP BY currency, month
)
SELECT
    currency,
    month,
    settled_revenue,
    settled_count,
    SUM(settled_revenue) OVER (
        PARTITION BY currency ORDER BY month
    ) AS cumulative_revenue,
    LAG(settled_revenue) OVER w AS prev_month_revenue,
    ROUND(
        100.0 * (settled_revenue - LAG(settled_revenue) OVER w)
        / NULLIF(LAG(settled_revenue) OVER w, 0),
        2
    ) AS mom_growth_pct
FROM monthly
WINDOW w AS (PARTITION BY currency ORDER BY month)
ORDER BY currency, month;

-- Cohort retention: customers grouped by first-payment month, activity
-- tracked by month offset. Same logic as the MySQL portfolio project,
-- expressed in BigQuery dialect — the pattern is portable, the syntax
-- isn't, and pretending otherwise is how warehouse migrations slip.
WITH first_payment AS (
    SELECT customer_id, DATE_TRUNC(DATE(paid_at), MONTH) AS cohort_month
    FROM `<project>.payments_analytics.payments_curated`
    WHERE DATE(paid_at) BETWEEN DATE '2025-01-01' AND DATE '2026-12-31'
      AND status = 'settled'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY customer_id ORDER BY paid_at
    ) = 1
),
activity AS (
    SELECT DISTINCT
        f.cohort_month,
        p.customer_id,
        DATE_DIFF(DATE_TRUNC(DATE(p.paid_at), MONTH), f.cohort_month, MONTH)
            AS period_index
    FROM first_payment AS f
    JOIN `<project>.payments_analytics.payments_curated` AS p
        ON p.customer_id = f.customer_id
    WHERE DATE(p.paid_at) BETWEEN DATE '2025-01-01' AND DATE '2026-12-31'
      AND p.status = 'settled'
),
sizes AS (
    SELECT cohort_month, COUNT(*) AS cohort_size
    FROM first_payment
    GROUP BY cohort_month
)
SELECT
    a.cohort_month,
    s.cohort_size,
    a.period_index,
    COUNT(DISTINCT a.customer_id) AS active_customers,
    ROUND(100.0 * COUNT(DISTINCT a.customer_id) / s.cohort_size, 2)
        AS retention_pct
FROM activity AS a
JOIN sizes AS s USING (cohort_month)
GROUP BY a.cohort_month, s.cohort_size, a.period_index
ORDER BY a.cohort_month, a.period_index;

-- Payment funnel by status with conversion between consecutive stages
-- (LAG over the stage sequence per day).
WITH stage_counts AS (
    SELECT
        DATE(paid_at) AS day,
        status,
        COUNT(*) AS payments,
        CASE status
            WHEN 'authorised' THEN 1
            WHEN 'settled' THEN 2
            WHEN 'failed' THEN 3
            WHEN 'voided' THEN 4
        END AS stage_order
    FROM `<project>.payments_analytics.payments_curated`
    WHERE DATE(paid_at) BETWEEN DATE '2026-06-01' AND DATE '2026-06-30'
    GROUP BY day, status, stage_order
)
SELECT
    day,
    status,
    payments,
    LAG(payments) OVER (PARTITION BY day ORDER BY stage_order) AS prev_stage,
    ROUND(
        100.0 * payments
        / NULLIF(LAG(payments) OVER (PARTITION BY day ORDER BY stage_order), 0),
        2
    ) AS pct_of_prev_stage
FROM stage_counts
ORDER BY day, stage_order;
