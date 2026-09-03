-- ============================================================
-- Karatly Admin Dashboard - Sell & Redeem Details
-- Database: sabbpekaratly (MariaDB)
--
-- Procs:
--   sp_dashboard_sells(p_days)    -> digital_sell orders with grams/rate/value
--   sp_dashboard_redeems(p_days)  -> physical_redemption orders with grams/address
--
-- Grams extraction:
--   SELL : Augmont stores grams in provider_response_payload.result.data.quantity
--          SafeGold stores grams in pricing_snapshot.quantity
--   REDEEM: grams live in order_items.quantity (+ items.weight catalog grams)
--          (NOT in pricing_snapshot, which is only {"assetType":"product"})
-- ============================================================

DELIMITER //

-- ============================================================
-- 1. SELL ORDERS (list)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_sells//

CREATE PROCEDURE sp_dashboard_sells(IN p_days INT)
proc: BEGIN
    DECLARE v_since DATE;
    SET v_since = DATE_SUB(CURDATE(), INTERVAL p_days DAY);

    SELECT
        o.order_id,
        o.order_reference,
        o.merchant_transaction_id,
        o.client_id,
        cp.full_name AS client_name,
        cp.mobile    AS client_mobile,
        COALESCE(
            JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')),
            JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')),
            'gold'
        ) AS metal_type,
        o.order_status,
        CAST(COALESCE(
            NULLIF(
                NULLIF(
                    COALESCE(
                        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')),
                        JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.quantity'))
                    ),
                    'null'
                ),
                ''
            ),
            '0'
        ) AS DECIMAL(18,6)) AS sold_grams,
        JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.pricePerUnit')) AS rate_per_gram,
        COALESCE(o.total_amount, 0) AS sell_value,
        UPPER(COALESCE(pt.payment_status, cfp.payment_status, 'PENDING')) AS payment_status,
        CASE WHEN cfo.id IS NOT NULL THEN 'CASHFREE' ELSE 'EASEBUZZ' END AS payment_gateway,
        o.provider_reference AS provider_txn_id,
        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.goldBalance')) AS gold_balance_after,
        JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.silverBalance')) AS silver_balance_after,
        DATE_FORMAT(o.created_at, '%Y-%m-%d %H:%i:%s') AS order_date
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
    LEFT JOIN cashfreepg_orders    cfo ON cfo.merchant_order_id = o.merchant_transaction_id
    LEFT JOIN cashfreepg_payments  cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
    WHERE o.order_type = 'digital_sell'
      AND o.created_at >= v_since
    ORDER BY o.created_at DESC;
END//

-- ============================================================
-- 2. REDEEM ORDERS (list, one row per order_item)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_redeems//

CREATE PROCEDURE sp_dashboard_redeems(IN p_days INT)
proc: BEGIN
    DECLARE v_since DATE;
    SET v_since = DATE_SUB(CURDATE(), INTERVAL p_days DAY);

    SELECT
        o.order_id,
        o.order_reference,
        o.client_id,
        cp.full_name AS client_name,
        cp.mobile    AS client_mobile,
        o.order_status,
        COALESCE(NULLIF(oi.asset_type, 'product'), i.metal_type, 'product') AS metal_type,
        oi.provider_sku,
        oi.quantity  AS item_grams,
        oi.unit,
        i.weight     AS product_weight_grams,
        oi.price_per_unit AS live_rate,
        COALESCE(oi.total_price, 0) AS item_value,
        COALESCE(o.total_amount, 0)      AS order_value,
        COALESCE(o.subtotal_amount, 0)   AS metal_value,
        COALESCE(o.shipping_amount, 0)   AS shipping_value,
        JSON_UNQUOTE(JSON_EXTRACT(o.shipping_address, '$.addressId')) AS address_id,
        o.shipping_address AS shipping_address,
        o.provider_reference AS provider_txn_id,
        DATE_FORMAT(o.created_at, '%Y-%m-%d %H:%i:%s') AS order_date
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    LEFT JOIN order_items oi ON oi.order_id = o.order_id
    LEFT JOIN items i       ON i.provider_sku = oi.provider_sku
    WHERE o.order_type = 'physical_redemption'
      AND o.created_at >= v_since
    ORDER BY o.created_at DESC;
END//

DELIMITER ;