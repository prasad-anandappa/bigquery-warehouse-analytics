-- ============================================================================
-- 02_customer_dim_scd2.sql — customer dimension, Slowly Changing Type 2.
--
-- One row per customer *version*: when a tracked attribute changes (segment,
-- country), the current row is closed (effective_to set, is_current=false)
-- and a new version opens. Facts join the version that was current when the
-- fact occurred — "what did we know about this customer at the time" stays
-- answerable, which a Type 1 overwrite destroys.
--
-- Surrogate key: FARM_FINGERPRINT over (customer_id, effective_from) —
-- stable, deterministic, and collision-safe enough for a dimension key.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `<project>.payments_analytics.dim_customers`
(
    customer_key    INT64     NOT NULL,   -- surrogate key (versioned)
    customer_id     STRING    NOT NULL,   -- natural key
    email           STRING,
    full_name       STRING,
    country_code    STRING,
    segment         STRING,               -- tracked attribute (Type 2)
    _row_hash       BYTES     NOT NULL,   -- SHA-256 over tracked attributes
    effective_from  TIMESTAMP NOT NULL,
    effective_to    TIMESTAMP,            -- NULL while current
    is_current      BOOL      NOT NULL DEFAULT TRUE
)
CLUSTER BY customer_id, is_current
OPTIONS (
    description = 'Customer dimension, SCD Type 2 with hash-diff change detection'
);

-- Incoming customer snapshots (one row per customer per delivery) land here
-- first; pipelines/02 diffs this against dim_customers.
CREATE TABLE IF NOT EXISTS `<project>.payments_analytics.customers_snapshot`
(
    customer_id   STRING NOT NULL,
    email         STRING,
    full_name     STRING,
    country_code  STRING,
    segment       STRING,
    updated_at    TIMESTAMP NOT NULL
)
OPTIONS (
    description = 'Latest customer snapshot as delivered; input to the SCD2 merge',
    expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
);
