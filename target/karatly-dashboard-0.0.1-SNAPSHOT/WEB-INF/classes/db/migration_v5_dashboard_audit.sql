-- ============================================================
-- Karatly Admin Dashboard - Order Audit Trail
-- Database: sabbpekaratly (MariaDB)
--
-- Procs:
--   sp_dashboard_order_audit(p_merchant_txn_id) -> full audit for one order
-- ============================================================

DELIMITER //

-- ============================================================
-- ORDER AUDIT: joins orders + cashfreepg_orders + cashfreepg_payments + cashfreepg_webhooks
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_order_audit//

CREATE PROCEDURE sp_dashboard_order_audit(IN p_merchant_txn_id VARCHAR(100))
proc: BEGIN
    SELECT
        o.order_id,
        o.merchant_transaction_id,
        o.order_type,
        o.order_status,
        COALESCE(o.total_amount, 0) AS total_amount,
        o.order_reference,
        o.provider_reference AS augmont_txn_id,
        o.failure_reason,
        DATE_FORMAT(o.created_at, '%Y-%m-%d %H:%i:%s') AS order_date,

        -- Cashfree order
        cfo.id AS cf_order_row_id,
        cfo.sabbpe_order_id AS cf_sabbpe_order_id,
        cfo.provider_order_id AS cf_provider_order_id,
        cfo.order_status AS cf_order_status,
        DATE_FORMAT(cfo.created_at, '%Y-%m-%d %H:%i:%s') AS cf_order_date,

        -- Cashfree payment
        cfp.id AS cf_payment_row_id,
        cfp.cf_payment_id,
        cfp.payment_status AS cf_payment_status,
        cfp.payment_method,
        cfp.bank_reference AS cf_rrn,
        DATE_FORMAT(cfp.created_at, '%Y-%m-%d %H:%i:%s') AS cf_payment_date,

        -- Cashfree webhook
        cfw.id AS cf_webhook_row_id,
        cfw.webhook_type,
        cfw.payment_status AS webhook_payment_status,
        cfw.processed AS webhook_processed,
        DATE_FORMAT(COALESCE(cfw.processed_time, cfw.created_at), '%Y-%m-%d %H:%i:%s') AS webhook_date,

        -- Easebuzz payment (fallback)
        pt.payment_id AS easebuzz_payment_id,
        pt.payment_status AS easebuzz_payment_status,

        -- Augmont gold response
        CAST(COALESCE(
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), ''),
            '0'
        ) AS DECIMAL(18,4)) AS augmont_quantity,
        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.goldBalance')) AS gold_balance,
        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.silverBalance')) AS silver_balance,
        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.invoiceNumber')) AS augmont_invoice,
        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.message')) AS augmont_message,
        CASE WHEN JSON_EXTRACT(o.provider_response_payload, '$.statusCode') IS NOT NULL
             THEN JSON_EXTRACT(o.provider_response_payload, '$.statusCode')
             ELSE NULL END AS augmont_status_code,

        -- Status flags
        CASE WHEN cfo.id IS NOT NULL THEN 'YES' ELSE 'NO' END AS cashfree_order_created,
        CASE WHEN cfw.id IS NOT NULL THEN 'YES' ELSE 'NO' END AS webhook_received,
        CASE WHEN cfp.id IS NOT NULL THEN 'YES' ELSE 'NO' END AS payment_recorded,
        CASE WHEN o.provider_reference IS NOT NULL AND TRIM(o.provider_reference) <> ''
             THEN 'YES' ELSE 'NO' END AS gold_purchased

    FROM orders o
    LEFT JOIN cashfreepg_orders   cfo ON cfo.merchant_order_id = o.merchant_transaction_id
    LEFT JOIN cashfreepg_payments cfp ON cfp.sabbpe_order_id   = cfo.sabbpe_order_id
    LEFT JOIN cashfreepg_webhooks cfw ON cfw.sabbpe_order_id   = cfo.sabbpe_order_id
    LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
    WHERE o.merchant_transaction_id = p_merchant_txn_id
    ORDER BY o.created_at DESC;
END//

DELIMITER ;
