-- ============================================================================
-- 02_scd2_customers.sql — apply a customer snapshot as SCD Type 2.
--
-- Change detection is by HASH DIFFING: SHA-256 over the tracked attributes
-- of the incoming row vs. the current dimension row. Comparing hashes
-- instead of column-by-column OR-chains is shorter, faster, and — the real
-- reason — impossible to get subtly wrong when a new tracked attribute is
-- added (it joins the hash input, once, in both places that compute it).
--
-- Two steps, and the order matters:
--   1. CLOSE: MERGE closes current rows whose hash changed, stamping
--      effective_to with the snapshot's updated_at.
--   2. OPEN: INSERT opens a new version for every customer whose hash
--      differs from the (now-closed) current row, and for new customers.
-- Doing it in one MERGE is a common mistake: BigQuery MERGE cannot insert
-- a replacement row for a target row it just updated in the same statement
-- in the way the pattern requires, and the two-step version is auditable.
--
-- Deletes: a customer absent from the snapshot is NOT closed — absence in
-- a snapshot usually means an incomplete extract, not a deletion. Hard
-- deletes need an explicit tombstone feed; this pipeline documents that
-- choice rather than guessing.
-- ============================================================================

DECLARE snapshot_at TIMESTAMP DEFAULT (
    SELECT MAX(updated_at)
    FROM `<project>.payments_analytics.customers_snapshot`
);

-- ------------------------------------------------------------ step 1: close
MERGE `<project>.payments_analytics.dim_customers` AS target
USING `<project>.payments_analytics.customers_snapshot` AS source
ON target.customer_id = source.customer_id AND target.is_current
WHEN MATCHED AND target._row_hash != SHA256(CONCAT(
        IFNULL(source.email, ''), '|', IFNULL(source.full_name, ''), '|',
        IFNULL(source.country_code, ''), '|', IFNULL(source.segment, '')
    )) THEN
    UPDATE SET
        effective_to = source.updated_at,
        is_current = FALSE;

-- ------------------------------------------------------------- step 2: open
INSERT INTO `<project>.payments_analytics.dim_customers`
    (customer_key, customer_id, email, full_name, country_code, segment,
     _row_hash, effective_from, effective_to, is_current)
SELECT
    FARM_FINGERPRINT(CONCAT(
        s.customer_id, '|', CAST(s.updated_at AS STRING))),
    s.customer_id,
    s.email,
    s.full_name,
    s.country_code,
    s.segment,
    SHA256(CONCAT(
        IFNULL(s.email, ''), '|', IFNULL(s.full_name, ''), '|',
        IFNULL(s.country_code, ''), '|', IFNULL(s.segment, '')
    )),
    s.updated_at,
    NULL,
    TRUE
FROM `<project>.payments_analytics.customers_snapshot` AS s
LEFT JOIN `<project>.payments_analytics.dim_customers` AS current_dim
    ON current_dim.customer_id = s.customer_id AND current_dim.is_current
WHERE current_dim.customer_id IS NULL
   OR current_dim._row_hash != SHA256(CONCAT(
        IFNULL(s.email, ''), '|', IFNULL(s.full_name, ''), '|',
        IFNULL(s.country_code, ''), '|', IFNULL(s.segment, '')
    ));
