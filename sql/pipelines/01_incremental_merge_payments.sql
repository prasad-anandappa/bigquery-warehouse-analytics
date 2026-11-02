-- ============================================================================
-- 01_incremental_merge_payments.sql — incremental load: raw -> curated.
--
-- Run model (driven by loader/load_payments.py or a scheduler):
--   1. The loader lands new/changed source rows into payments_staging.
--   2. This script MERGEs staging into payments_curated.
--   3. The watermark in etl_state advances — inside the same script, after
--      the MERGE, so a failed merge never advances the watermark.
--
-- Three properties are engineered in, deliberately:
--
-- * IDEMPOTENT — re-running with the same staging contents changes nothing:
--   the hash comparison makes no-op deliveries produce no updates.
-- * LATE-DATA SAFE — the source side is deduplicated to the newest version
--   per payment_id (QUALIFY ROW_NUMBER), and the watermark only bounds
--   what the *loader* fetches; a late-arriving correction with an older
--   updated_at still merges correctly because matching is by key + hash,
--   not by watermark. (A watermark-only design silently drops late data.)
-- * CHANGE-AWARE — a re-delivered row whose business columns changed
--   updates; one that didn't, doesn't (no fake "updated" churn downstream).
-- ============================================================================

DECLARE run_batch_id STRING DEFAULT CONCAT('merge-', FORMAT_TIMESTAMP('%Y%m%d%H%M%S', CURRENT_TIMESTAMP()));

-- ------------------------------------------------------------------ MERGE
MERGE `<project>.payments_analytics.payments_curated` AS target
USING (
    SELECT
        s.*,
        SHA256(CONCAT(
            s.order_id, '|', s.customer_id, '|',
            CAST(s.amount AS STRING), '|', s.currency, '|', s.status, '|',
            CAST(s.paid_at AS STRING)
        )) AS row_hash
    FROM `<project>.payments_analytics.payments_staging` AS s
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY s.payment_id ORDER BY s.updated_at DESC
    ) = 1
) AS source
ON target.payment_id = source.payment_id
WHEN MATCHED AND target._row_hash != source.row_hash THEN
    UPDATE SET
        order_id   = source.order_id,
        customer_id = source.customer_id,
        amount     = source.amount,
        currency   = source.currency,
        status     = source.status,
        paid_at    = source.paid_at,
        updated_at = source.updated_at,
        _row_hash  = source.row_hash,
        _loaded_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
    INSERT (payment_id, order_id, customer_id, amount, currency, status,
            paid_at, updated_at, _row_hash, _loaded_at)
    VALUES (source.payment_id, source.order_id, source.customer_id,
            source.amount, source.currency, source.status,
            source.paid_at, source.updated_at, source.row_hash,
            CURRENT_TIMESTAMP());

-- ------------------------------------------------------- watermark advance
-- Only reached if the MERGE succeeded (script execution stops on error).
INSERT INTO `<project>.payments_analytics.etl_state`
    (pipeline_name, watermark, last_run_at, last_batch_id, rows_merged)
SELECT
    'payments_incremental',
    (SELECT MAX(updated_at) FROM `<project>.payments_analytics.payments_staging`),
    CURRENT_TIMESTAMP(),
    run_batch_id,
    (SELECT COUNT(*) FROM `<project>.payments_analytics.payments_staging`)
WHERE EXISTS (SELECT 1 FROM `<project>.payments_analytics.payments_staging`);
