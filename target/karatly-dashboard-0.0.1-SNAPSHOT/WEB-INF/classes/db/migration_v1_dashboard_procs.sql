-- ============================================================
-- Karatly Admin Dashboard - Stored Procedures
-- Database: sabbpekaratly (MariaDB)
--
-- All dashboard logic lives here (no new tables).
-- Java backend only calls these procs and maps the result sets.
--
-- Procedure list:
--   sp_dashboard_kpis(p_days)            -> single-row KPI summary
--   sp_dashboard_daily(p_days)           -> day-wise trend rows
--   sp_dashboard_users(p_from,p_to,p_search,p_kyc) -> per-user list
--   sp_dashboard_user_profile(p_client_id)          -> single-user KPIs
--   sp_dashboard_user_orders(p_client_id)           -> single-user orders
--   sp_dashboard_user_banks(p_client_id)            -> single-user banks
--   sp_dashboard_user_addresses(p_client_id)        -> single-user addresses
--
-- Convention:
--   "stock" metrics (total users / KYC / bank / address) are ALL-TIME.
--   "flow" metrics (gold, silver, sells, redeems, money) are within
--   the selected window (last p_days).
-- ============================================================

DELIMITER //

-- ============================================================
-- 1. KPI SUMMARY (one row)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_kpis//

CREATE PROCEDURE sp_dashboard_kpis(IN p_days INT)
proc: BEGIN
    DECLARE v_since DATE;
    SET v_since = DATE_SUB(CURDATE(), INTERVAL p_days DAY);

    SELECT
        u.total_users,
        u.kyc_completed,
        u.bank_validated,
        u.users_with_address,
        t.total_collected,
        t.gold_grams,
        t.silver_grams,
        t.gold_value,
        t.silver_value,
        t.sell_count,
        t.sell_value,
        t.redeem_count,
        t.redeem_value,
        t.paid_no_gold,
        t.gold_no_payment,
        t.gold_and_payment
    FROM (
        SELECT
            (SELECT COUNT(*) FROM client_profile) AS total_users,
            (SELECT COUNT(*) FROM client_profile
              WHERE pan_verified = 1 AND aadhaar_verified = 1 AND bank_verified = 1) AS kyc_completed,
            (SELECT COUNT(*) FROM client_profile WHERE bank_verified = 1) AS bank_validated,
            (SELECT COUNT(DISTINCT client_id) FROM client_addresses) AS users_with_address
    ) u
    CROSS JOIN (
        SELECT
            COALESCE(SUM(CASE WHEN UPPER(COALESCE(x.pt_status, x.cfp_status,'')) = 'SUCCESS'
                              THEN x.total_amount ELSE 0 END), 0) AS total_collected,
            COALESCE(SUM(CASE WHEN x.order_type = 'digital_purchase'
                               AND x.metal_type = 'gold'
                               AND x.order_status IN ('completed','confirmed')
                              THEN x.qty ELSE 0 END), 0) AS gold_grams,
            COALESCE(SUM(CASE WHEN x.order_type = 'digital_purchase'
                               AND x.metal_type = 'silver'
                               AND x.order_status IN ('completed','confirmed')
                              THEN x.qty ELSE 0 END), 0) AS silver_grams,
            COALESCE(SUM(CASE WHEN x.order_type = 'digital_purchase'
                               AND x.metal_type = 'gold'
                              THEN x.total_amount ELSE 0 END), 0) AS gold_value,
            COALESCE(SUM(CASE WHEN x.order_type = 'digital_purchase'
                               AND x.metal_type = 'silver'
                              THEN x.total_amount ELSE 0 END), 0) AS silver_value,
            COALESCE(SUM(CASE WHEN x.order_type = 'digital_sell' THEN 1 ELSE 0 END), 0) AS sell_count,
            COALESCE(SUM(CASE WHEN x.order_type = 'digital_sell' THEN x.total_amount ELSE 0 END), 0) AS sell_value,
            COALESCE(SUM(CASE WHEN x.order_type = 'physical_redemption' THEN 1 ELSE 0 END), 0) AS redeem_count,
            COALESCE(SUM(CASE WHEN x.order_type = 'physical_redemption' THEN x.total_amount ELSE 0 END), 0) AS redeem_value,
            COALESCE(SUM(CASE WHEN x.order_type = 'digital_purchase'
                               AND UPPER(COALESCE(x.pt_status, x.cfp_status,'')) = 'SUCCESS'
                               AND (x.provider_reference IS NULL OR TRIM(x.provider_reference) = '')
                              THEN 1 ELSE 0 END), 0) AS paid_no_gold,
            COALESCE(SUM(CASE WHEN x.order_type = 'digital_purchase'
                               AND (x.provider_reference IS NOT NULL AND TRIM(x.provider_reference) <> '')
                               AND UPPER(COALESCE(x.pt_status, x.cfp_status,'')) <> 'SUCCESS'
                              THEN 1 ELSE 0 END), 0) AS gold_no_payment,
            COALESCE(SUM(CASE WHEN x.order_type = 'digital_purchase'
                               AND UPPER(COALESCE(x.pt_status, x.cfp_status,'')) = 'SUCCESS'
                               AND (x.provider_reference IS NOT NULL AND TRIM(x.provider_reference) <> '')
                              THEN 1 ELSE 0 END), 0) AS gold_and_payment
        FROM (
            SELECT
                o.order_type,
                o.order_status,
                o.provider_reference,
                o.created_at,
                COALESCE(o.total_amount, 0) AS total_amount,
                COALESCE(
                    JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')),
                    JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')),
                    'gold'
                ) AS metal_type,
                CAST(COALESCE(
                    NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), ''),
                    NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.quantity')), ''),
                    '0'
                ) AS DECIMAL(18,4)) AS qty,
                pt.payment_status  AS pt_status,
                cfp.payment_status AS cfp_status
            FROM orders o
            LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
            LEFT JOIN cashfreepg_orders    cfo ON cfo.merchant_order_id = o.merchant_transaction_id
            LEFT JOIN cashfreepg_payments  cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
        ) x
        WHERE x.created_at >= v_since
    ) t;
END//

-- ============================================================
-- 2. DAY-WISE TREND (one row per date)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_daily//

CREATE PROCEDURE sp_dashboard_daily(IN p_days INT)
proc: BEGIN
    DECLARE v_since DATE;
    SET v_since = DATE_SUB(CURDATE(), INTERVAL p_days DAY);

    WITH RECURSIVE dates AS (
        SELECT v_since AS d
        UNION ALL
        SELECT d + INTERVAL 1 DAY FROM dates WHERE d < CURDATE()
    )
    SELECT
        DATE_FORMAT(d.d, '%Y-%m-%d') AS date,
        COALESCE(u.cnt, 0) AS new_registrations,
        COALESCE(b.cnt, 0) AS bank_validations,
        COALESCE(o.sell_count, 0)    AS sells,
        COALESCE(o.sell_amount, 0)   AS sell_amount,
        COALESCE(o.redeem_count, 0)  AS redeems,
        COALESCE(o.redeem_amount, 0) AS redeem_amount,
        COALESCE(o.gold_grams, 0)    AS gold_grams,
        COALESCE(o.gold_amount, 0)   AS gold_amount,
        COALESCE(o.silver_grams, 0)  AS silver_grams,
        COALESCE(o.silver_amount, 0) AS silver_amount,
        COALESCE(o.cash_collected, 0) AS cash_collected,
        COALESCE(o.txn_count, 0)     AS transactions
    FROM dates d
    LEFT JOIN (
        SELECT DATE(created_at) AS dt, COUNT(*) AS cnt
        FROM client_profile
        WHERE created_at >= v_since
        GROUP BY DATE(created_at)
    ) u ON u.dt = d.d
    LEFT JOIN (
        SELECT DATE(created_at) AS dt, COUNT(*) AS cnt
        FROM client_bank_accounts
        WHERE created_at >= v_since
        GROUP BY DATE(created_at)
    ) b ON b.dt = d.d
    LEFT JOIN (
        SELECT
            DATE(x.created_at) AS dt,
            COUNT(*) AS txn_count,
            SUM(CASE WHEN x.order_type = 'digital_sell' THEN 1 ELSE 0 END) AS sell_count,
            SUM(CASE WHEN x.order_type = 'digital_sell' THEN x.total_amount ELSE 0 END) AS sell_amount,
            SUM(CASE WHEN x.order_type = 'physical_redemption' THEN 1 ELSE 0 END) AS redeem_count,
            SUM(CASE WHEN x.order_type = 'physical_redemption' THEN x.total_amount ELSE 0 END) AS redeem_amount,
            SUM(CASE WHEN x.order_type = 'digital_purchase'
                      AND x.metal_type = 'gold'
                      AND x.order_status IN ('completed','confirmed')
                     THEN x.qty ELSE 0 END) AS gold_grams,
            SUM(CASE WHEN x.order_type = 'digital_purchase'
                      AND x.metal_type = 'gold'
                     THEN x.total_amount ELSE 0 END) AS gold_amount,
            SUM(CASE WHEN x.order_type = 'digital_purchase'
                      AND x.metal_type = 'silver'
                      AND x.order_status IN ('completed','confirmed')
                     THEN x.qty ELSE 0 END) AS silver_grams,
            SUM(CASE WHEN x.order_type = 'digital_purchase'
                      AND x.metal_type = 'silver'
                     THEN x.total_amount ELSE 0 END) AS silver_amount,
            SUM(CASE WHEN UPPER(COALESCE(x.pt_status, x.cfp_status,'')) = 'SUCCESS'
                     THEN x.total_amount ELSE 0 END) AS cash_collected
        FROM (
            SELECT
                o.order_type,
                o.order_status,
                o.created_at,
                COALESCE(o.total_amount, 0) AS total_amount,
                COALESCE(
                    JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')),
                    JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')),
                    'gold'
                ) AS metal_type,
                CAST(COALESCE(
                    NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), ''),
                    NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.quantity')), ''),
                    '0'
                ) AS DECIMAL(18,4)) AS qty,
                pt.payment_status  AS pt_status,
                cfp.payment_status AS cfp_status
            FROM orders o
            LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
            LEFT JOIN cashfreepg_orders    cfo ON cfo.merchant_order_id = o.merchant_transaction_id
            LEFT JOIN cashfreepg_payments  cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
        ) x
        WHERE x.created_at >= v_since
        GROUP BY DATE(x.created_at)
    ) o ON o.dt = d.d
    ORDER BY d.d ASC;
END//

-- ============================================================
-- 3. PER-USER LIST (one row per user)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_users//

CREATE PROCEDURE sp_dashboard_users(
    IN p_from   VARCHAR(10),
    IN p_to     VARCHAR(10),
    IN p_search VARCHAR(120),
    IN p_kyc    VARCHAR(20)
)
proc: BEGIN
    SELECT
        cp.client_id,
        cp.full_name    AS name,
        cp.mobile,
        cp.email,
        COALESCE(cp.kyc_status, 'pending') AS kyc_status,
        cp.pan_verified,
        cp.aadhaar_verified,
        cp.bank_verified,
        cp.provider_client_reference AS augmont_unique_id,
        DATE_FORMAT(cp.created_at, '%Y-%m-%d %H:%i:%s') AS registered_at,
        (SELECT COUNT(*) FROM client_bank_accounts cba
          WHERE cba.client_id = cp.client_id) AS bank_accounts,
        (SELECT cba.account_holder_name FROM client_bank_accounts cba
          WHERE cba.client_id = cp.client_id AND cba.is_primary = 1
          ORDER BY cba.updated_at DESC LIMIT 1) AS primary_bank_holder,
        (SELECT cba.account_number FROM client_bank_accounts cba
          WHERE cba.client_id = cp.client_id AND cba.is_primary = 1
          ORDER BY cba.updated_at DESC LIMIT 1) AS primary_bank_number,
        (SELECT cba.ifsc_code FROM client_bank_accounts cba
          WHERE cba.client_id = cp.client_id AND cba.is_primary = 1
          ORDER BY cba.updated_at DESC LIMIT 1) AS primary_bank_ifsc,
        (SELECT COUNT(*) FROM client_addresses ca
          WHERE ca.client_id = cp.client_id) AS delivery_addresses,
        COALESCE(agg.buy_count, 0)      AS buy_count,
        COALESCE(agg.buy_amount, 0)     AS buy_amount,
        COALESCE(agg.gold_grams, 0)     AS gold_grams,
        COALESCE(agg.silver_grams, 0)   AS silver_grams,
        COALESCE(agg.sell_count, 0)     AS sell_count,
        COALESCE(agg.sell_amount, 0)    AS sell_amount,
        COALESCE(agg.redeem_count, 0)   AS redeem_count,
        COALESCE(agg.redeem_amount, 0)  AS redeem_amount,
        COALESCE(agg.last_activity, NULL) AS last_activity
    FROM client_profile cp
    LEFT JOIN (
        SELECT
            x.client_id,
            SUM(CASE WHEN x.order_type = 'digital_purchase' THEN 1 ELSE 0 END) AS buy_count,
            SUM(CASE WHEN x.order_type = 'digital_purchase' THEN x.total_amount ELSE 0 END) AS buy_amount,
            SUM(CASE WHEN x.order_type = 'digital_purchase' AND x.metal_type = 'gold'
                      AND x.order_status IN ('completed','confirmed')
                     THEN x.qty ELSE 0 END) AS gold_grams,
            SUM(CASE WHEN x.order_type = 'digital_purchase' AND x.metal_type = 'silver'
                      AND x.order_status IN ('completed','confirmed')
                     THEN x.qty ELSE 0 END) AS silver_grams,
            SUM(CASE WHEN x.order_type = 'digital_sell' THEN 1 ELSE 0 END) AS sell_count,
            SUM(CASE WHEN x.order_type = 'digital_sell' THEN x.total_amount ELSE 0 END) AS sell_amount,
            SUM(CASE WHEN x.order_type = 'physical_redemption' THEN 1 ELSE 0 END) AS redeem_count,
            SUM(CASE WHEN x.order_type = 'physical_redemption' THEN x.total_amount ELSE 0 END) AS redeem_amount,
            MAX(DATE_FORMAT(x.created_at, '%Y-%m-%d %H:%i:%s')) AS last_activity
        FROM (
            SELECT
                o.client_id,
                o.order_type,
                o.order_status,
                o.created_at,
                COALESCE(o.total_amount, 0) AS total_amount,
                COALESCE(
                    JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')),
                    JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')),
                    'gold'
                ) AS metal_type,
                CAST(COALESCE(
                    NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), ''),
                    NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.quantity')), ''),
                    '0'
                ) AS DECIMAL(18,4)) AS qty
            FROM orders o
        ) x
        GROUP BY x.client_id
    ) agg ON agg.client_id = cp.client_id
    WHERE 1 = 1
      AND (p_from IS NULL OR p_from = '' OR cp.created_at >= CAST(p_from AS DATETIME))
      AND (p_to   IS NULL OR p_to   = '' OR cp.created_at <  DATE_ADD(CAST(p_to AS DATETIME), INTERVAL 1 DAY))
      AND (p_search IS NULL OR p_search = ''
           OR cp.full_name LIKE CONCAT('%', p_search, '%')
           OR cp.mobile    LIKE CONCAT('%', p_search, '%')
           OR cp.email     LIKE CONCAT('%', p_search, '%'))
      AND (p_kyc IS NULL OR p_kyc = '' OR COALESCE(cp.kyc_status,'pending') = p_kyc)
    ORDER BY cp.created_at DESC;
END//

-- ============================================================
-- 4. SINGLE USER - PROFILE / KPIs (one row)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_user_profile//

CREATE PROCEDURE sp_dashboard_user_profile(IN p_client_id VARCHAR(36))
proc: BEGIN
    SELECT
        cp.client_id,
        cp.full_name    AS name,
        cp.mobile,
        cp.email,
        cp.date_of_birth,
        cp.city,
        cp.state,
        cp.pincode,
        COALESCE(cp.kyc_status, 'pending') AS kyc_status,
        cp.pan_verified,
        cp.aadhaar_verified,
        cp.bank_verified,
        cp.pan_number,
        cp.pan_name,
        cp.provider_client_reference AS augmont_unique_id,
        DATE_FORMAT(cp.kyc_completed_at, '%Y-%m-%d %H:%i:%s') AS kyc_completed_at,
        DATE_FORMAT(cp.created_at, '%Y-%m-%d %H:%i:%s') AS registered_at,
        (SELECT COUNT(*) FROM client_bank_accounts cba
          WHERE cba.client_id = cp.client_id) AS bank_accounts,
        (SELECT COUNT(*) FROM client_addresses ca
          WHERE ca.client_id = cp.client_id) AS delivery_addresses,
        (SELECT CONCAT_WS(', ', ca.address_line, ca.city, ca.state, ca.pincode)
         FROM client_addresses ca
         WHERE ca.client_id = cp.client_id
           AND JSON_UNQUOTE(JSON_EXTRACT(ca.request_payload, '$.addressSource')) = 'AADHAAR'
         ORDER BY ca.updated_at DESC LIMIT 1) AS primary_address
    FROM client_profile cp
    WHERE cp.client_id = p_client_id;
END//

-- ============================================================
-- 5. SINGLE USER - ORDERS (many rows)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_user_orders//

CREATE PROCEDURE sp_dashboard_user_orders(IN p_client_id VARCHAR(36))
proc: BEGIN
    SELECT
        o.order_id,
        o.order_reference,
        o.merchant_transaction_id,
        o.order_type,
        o.order_status,
        o.provider_reference AS augmont_txn_id,
        COALESCE(o.total_amount, 0) AS amount,
        COALESCE(o.subtotal_amount, 0) AS subtotal_amount,
        COALESCE(o.tax_amount, 0) AS tax_amount,
        COALESCE(
            JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')),
            JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')),
            'gold'
        ) AS metal_type,
        CAST(COALESCE(
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), ''),
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.quantity')), ''),
            '0'
        ) AS DECIMAL(18,4)) AS quantity,
        o.tracking_number,
        o.shipping_address,
        DATE_FORMAT(o.created_at, '%Y-%m-%d %H:%i:%s') AS order_date
    FROM orders o
    WHERE o.client_id = p_client_id
    ORDER BY o.created_at DESC;
END//

-- ============================================================
-- 6. SINGLE USER - BANK ACCOUNTS (many rows)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_user_banks//

CREATE PROCEDURE sp_dashboard_user_banks(IN p_client_id VARCHAR(36))
proc: BEGIN
    SELECT
        cba.bank_account_id,
        cba.provider_bank_id,
        cba.account_holder_name,
        cba.account_number,
        cba.ifsc_code,
        cba.status,
        cba.is_primary,
        cba.provider,
        DATE_FORMAT(cba.created_at, '%Y-%m-%d %H:%i:%s') AS created_at
    FROM client_bank_accounts cba
    WHERE cba.client_id = p_client_id
    ORDER BY cba.is_primary DESC, cba.created_at DESC;
END//

-- ============================================================
-- 7. SINGLE USER - ADDRESSES (many rows)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_user_addresses//

CREATE PROCEDURE sp_dashboard_user_addresses(IN p_client_id VARCHAR(36))
proc: BEGIN
    SELECT
        ca.address_id,
        ca.provider,
        ca.provider_address_id,
        ca.name,
        ca.mobile_number,
        ca.email,
        ca.address_line,
        ca.city,
        ca.state,
        ca.pincode,
        ca.country,
        JSON_UNQUOTE(JSON_EXTRACT(ca.request_payload, '$.addressSource')) AS address_source,
        CASE WHEN JSON_UNQUOTE(JSON_EXTRACT(ca.request_payload, '$.addressSource')) = 'AADHAAR'
             THEN 1 ELSE 0 END AS is_primary,
        DATE_FORMAT(ca.created_at, '%Y-%m-%d %H:%i:%s') AS created_at
    FROM client_addresses ca
    WHERE ca.client_id = p_client_id
    ORDER BY is_primary DESC, ca.created_at DESC;
END//

DELIMITER ;
