-- ============================================================
-- Karatly Admin Dashboard - Orders Summary & Recent Transactions
-- Database: sabbpekaratly (MariaDB)
--
-- Procs:
--   sp_dashboard_orders_summary(p_days)             -> single-row counts
--   sp_dashboard_recent_transactions(p_days,p_limit,p_status) -> list
-- ============================================================

DELIMITER //

-- ============================================================
-- 1. ORDERS SUMMARY (one row)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_orders_summary//

CREATE PROCEDURE sp_dashboard_orders_summary(IN p_days INT)
proc: BEGIN
    DECLARE v_since DATE;
    SET v_since = DATE_SUB(CURDATE(), INTERVAL p_days DAY);

    SELECT
        COALESCE(SUM(CASE WHEN x.order_type = 'digital_purchase' THEN 1 ELSE 0 END), 0) AS buy_count,
        COALESCE(SUM(CASE WHEN x.order_type = 'digital_sell' THEN 1 ELSE 0 END), 0)     AS sell_count,
        COALESCE(SUM(CASE WHEN x.order_type = 'physical_redemption' THEN 1 ELSE 0 END), 0) AS redeem_count,
        COALESCE(COUNT(*), 0) AS total_orders,

        COALESCE(SUM(CASE WHEN x.order_status IN ('completed','confirmed') THEN 1 ELSE 0 END), 0) AS order_success,
        COALESCE(SUM(CASE WHEN x.order_status IN ('failed','cancelled','fulfillment_failed') THEN 1 ELSE 0 END), 0) AS order_failed,
        COALESCE(SUM(CASE WHEN x.order_status NOT IN ('completed','confirmed','failed','cancelled','fulfillment_failed') THEN 1 ELSE 0 END), 0) AS order_pending,

        COALESCE(SUM(CASE WHEN UPPER(COALESCE(x.pt_status, x.cfp_status,'')) = 'SUCCESS' THEN 1 ELSE 0 END), 0) AS payment_paid,
        COALESCE(SUM(CASE WHEN UPPER(COALESCE(x.pt_status, x.cfp_status,'')) = 'FAILED' THEN 1 ELSE 0 END), 0) AS payment_failed,
        COALESCE(SUM(CASE WHEN UPPER(COALESCE(x.pt_status, x.cfp_status,'')) NOT IN ('SUCCESS','FAILED') THEN 1 ELSE 0 END), 0) AS payment_pending,

        COALESCE(SUM(CASE WHEN x.order_type = 'digital_purchase'
                           AND (x.provider_reference IS NOT NULL AND TRIM(x.provider_reference) <> '')
                          THEN 1 ELSE 0 END), 0) AS augmont_purchased,
        COALESCE(SUM(CASE WHEN x.order_type = 'digital_purchase'
                           AND UPPER(COALESCE(x.pt_status, x.cfp_status,'')) = 'SUCCESS'
                           AND (x.provider_reference IS NULL OR TRIM(x.provider_reference) = '')
                          THEN 1 ELSE 0 END), 0) AS paid_no_gold,
        COALESCE(SUM(CASE WHEN UPPER(COALESCE(x.pt_status, x.cfp_status,'')) = 'SUCCESS'
                          THEN x.total_amount ELSE 0 END), 0) AS total_collected
    FROM (
        SELECT
            o.order_type,
            o.order_status,
            o.provider_reference,
            o.created_at,
            COALESCE(o.total_amount, 0) AS total_amount,
            pt.payment_status  AS pt_status,
            cfp.payment_status AS cfp_status
        FROM orders o
        LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
        LEFT JOIN cashfreepg_orders    cfo ON cfo.merchant_order_id = o.merchant_transaction_id
        LEFT JOIN cashfreepg_payments  cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
        WHERE o.order_type IN ('digital_purchase','digital_sell','physical_redemption')
    ) x
    WHERE x.created_at >= v_since;
END//

-- ============================================================
-- 2. RECENT TRANSACTIONS (list)
--    p_status: ALL | SUCCESS | FAILED | PENDING
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_recent_transactions//

CREATE PROCEDURE sp_dashboard_recent_transactions(
    IN p_days   INT,
    IN p_limit  INT,
    IN p_status VARCHAR(20)
)
proc: BEGIN
    DECLARE v_since DATE;
    SET v_since = DATE_SUB(CURDATE(), INTERVAL p_days DAY);

    SELECT
        o.order_id,
        o.order_reference,
        o.merchant_transaction_id,
        o.order_type,
        o.order_status,
        o.provider_reference AS augmont_txn_id,
        cp.full_name AS client_name,
        cp.mobile   AS client_mobile,
        COALESCE(
            JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')),
            JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')),
            'gold'
        ) AS metal_type,
        COALESCE(o.total_amount, 0) AS amount,
        UPPER(COALESCE(pt.payment_status, cfp.payment_status, 'PENDING')) AS payment_status,
        CASE WHEN cfo.id IS NOT NULL THEN 'CASHFREE' ELSE 'EASEBUZZ' END AS payment_gateway,
        COALESCE(pt.payment_id, cfp.cf_payment_id) AS payment_id,
        COALESCE(
            JSON_UNQUOTE(JSON_EXTRACT(pt.response_payload, '$.rrn')),
            cfp.bank_reference
        ) AS rrn,

        /* --- Augmont gold response (from orders.provider_response_payload) --- */
        CAST(COALESCE(
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), ''),
            '0'
        ) AS DECIMAL(18,4)) AS augmont_quantity,
        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.goldBalance')) AS gold_balance_after,
        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.silverBalance')) AS silver_balance_after,
        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.invoiceNumber')) AS augmont_invoice,
        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.taxes.totalTaxAmount')) AS tax_amount,
        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.message')) AS augmont_message,
        COALESCE(
            o.failure_reason,
            CASE WHEN o.provider_response_payload IS NOT NULL
                  AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.statusCode')), '') NOT IN ('', 'null')
                  AND JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.statusCode')) <> '200'
                 THEN JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.message'))
                 ELSE NULL END
        ) AS augmont_error,
        DATE_FORMAT(o.created_at, '%Y-%m-%d %H:%i:%s') AS order_date
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
    LEFT JOIN cashfreepg_orders    cfo ON cfo.merchant_order_id = o.merchant_transaction_id
    LEFT JOIN cashfreepg_payments  cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
    WHERE o.order_type IN ('digital_purchase','digital_sell','physical_redemption')
      AND o.created_at >= v_since
      AND (
        p_status IS NULL OR p_status = '' OR p_status = 'ALL'
        OR (p_status = 'SUCCESS' AND UPPER(COALESCE(pt.payment_status, cfp.payment_status, '')) = 'SUCCESS')
        OR (p_status = 'FAILED'  AND UPPER(COALESCE(pt.payment_status, cfp.payment_status, '')) = 'FAILED')
        OR (p_status = 'PENDING' AND UPPER(COALESCE(pt.payment_status, cfp.payment_status, '')) NOT IN ('SUCCESS','FAILED'))
      )
    ORDER BY o.created_at DESC
    LIMIT p_limit;
END//

DELIMITER ;
