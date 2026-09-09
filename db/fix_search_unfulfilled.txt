-- FIX: cashfree search + unfulfilled queries
-- cashfreepg_orders.customer_id = provider_client_reference (NOT client_id)
-- Run this on sabbpekaratly DB

DELIMITER //

-- Fix 1: sp_dashboard_search_cashfree
DROP PROCEDURE IF EXISTS sp_dashboard_search_cashfree//
CREATE PROCEDURE sp_dashboard_search_cashfree(IN p_term VARCHAR(100))
BEGIN
    SELECT
        cf.sabbpe_order_id,
        cf.merchant_order_id,
        cf.customer_id,
        cf.customer_name,
        cf.customer_mobile,
        cf.order_amount,
        cf.order_status                                      AS cashfree_order_status,
        o.order_status                                       AS order_status,
        o.provider_reference                                 AS augmont_transaction_id,
        o.provider_response_payload                          AS augmont_response,
        o.failure_reason                                     AS augmont_failure_reason,
        cf.remarks                                           AS fulfillment_status,
        p.payment_status,
        p.cf_payment_id,
        CASE WHEN cf.remarks LIKE 'FULFILLMENT_COMPLETED%'
             THEN 1 ELSE 0 END                              AS gold_received,
        DATE_FORMAT(cf.created_at, '%Y-%m-%d %H:%i:%s')    AS created_at
    FROM cashfreepg_orders cf
    LEFT JOIN cashfreepg_payments p ON p.sabbpe_order_id = cf.sabbpe_order_id
    WHERE cf.customer_id IN (
        SELECT cp.provider_client_reference FROM client_profile cp
        WHERE cp.full_name LIKE CONCAT('%', p_term, '%')
           OR cp.mobile LIKE CONCAT('%', p_term, '%')
           OR cp.email LIKE CONCAT('%', p_term, '%')
           OR cp.provider_client_reference LIKE CONCAT('%', p_term, '%')
    )
    ORDER BY cf.created_at DESC;
END//

-- Fix 2: sp_dashboard_unfulfilled_cashfree
DROP PROCEDURE IF EXISTS sp_dashboard_unfulfilled_cashfree//
CREATE PROCEDURE sp_dashboard_unfulfilled_cashfree(
    IN p_days INT,
    IN p_status VARCHAR(20)
)
BEGIN
    SELECT
        cf.sabbpe_order_id,
        cf.merchant_order_id,
        cf.customer_id,
        cf.customer_name,
        cf.customer_mobile,
        cf.order_amount,
        cf.order_status,
        cf.remarks                                           AS fulfillment_status,
        p.payment_status,
        p.cf_payment_id,
        cp.provider_client_reference                         AS provider_reference,
        DATE_FORMAT(cf.created_at, '%Y-%m-%d %H:%i:%s')    AS created_at
    FROM cashfreepg_orders cf
    LEFT JOIN cashfreepg_payments p  ON p.sabbpe_order_id = cf.sabbpe_order_id
    LEFT JOIN client_profile cp      ON cp.provider_client_reference = cf.customer_id
    LEFT JOIN orders o                ON o.merchant_transaction_id = cf.merchant_order_id
    WHERE UPPER(p.payment_status) = 'SUCCESS'
      AND COALESCE(cf.remarks, '') NOT LIKE 'FULFILLMENT_COMPLETED'
      AND cf.created_at >= DATE_SUB(NOW(), INTERVAL p_days DAY)
      AND (
          p_status = 'ALL'
          OR (p_status = 'FAILED' AND UPPER(COALESCE(cf.remarks, '')) LIKE 'FULFILLMENT_FAILED%')
          OR (p_status = 'PENDING' AND (cf.remarks IS NULL OR TRIM(cf.remarks) = ''))
      )
    ORDER BY cf.created_at DESC;
END//

DELIMITER ;
