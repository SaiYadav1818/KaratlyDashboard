-- ============================================================
-- KARATLY DASHBOARD - EXECUTE THIS ENTIRE FILE ON THE UAT DB
-- DB: sabbpekaratly  (host 34.47.168.236:7306)
--
-- HOW TO RUN (command line):
--   mysql -h 34.47.168.236 -P 7306 -u sbuser -p sabbpekaratly < execute_all_dashboard.sql
--   (or open this file in HeidiSQL / MySQL Workbench and run all)
--
-- CONTENTS (in order):
--   PART 1 : dashboard procs (sp_dashboard_kpis/daily/users/user_*)
--   PART 2 : admin auth  (table dashboard_admin_users + sp_dashboard_admin_*)
--   PART 3 : orders summary + recent transactions procs
--
-- NOTE:
--   * Every proc uses DROP PROCEDURE IF EXISTS -> SAFE to re-run.
--   * PART 2 creates table dashboard_admin_users and seeds a
--     super admin: phone 9999999999 / password admin@123
--     (CHANGE THIS PASSWORD AFTER FIRST LOGIN).
-- ============================================================

-- ===================== PART 1 =====================
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
        d.d AS date,
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
        DATE_FORMAT(cp.created_at, '%Y-%m-%d %H:%i:%s') AS registered_at,
        (SELECT COUNT(*) FROM client_bank_accounts cba
          WHERE cba.client_id = cp.client_id) AS bank_accounts,
        (SELECT cba.account_number FROM client_bank_accounts cba
          WHERE cba.client_id = cp.client_id AND cba.is_primary = 1
          ORDER BY cba.updated_at DESC LIMIT 1) AS primary_account,
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

-- ===================== PART 2 =====================
-- ============================================================
-- Karatly Admin Dashboard - Admin Authentication
-- Database: sabbpekaratly (MariaDB)
--
-- Table: dashboard_admin_users  (the ONLY new table ??? for admin login)
-- Procs: sp_dashboard_admin_*
--
-- Password hashing is BCrypt (done in Java ??? MariaDB has no BCrypt).
-- Procs store/retrieve the hash only.
-- ============================================================

DELIMITER //

-- ============================================================
-- Admin users table
-- ============================================================
CREATE TABLE IF NOT EXISTS dashboard_admin_users (
    id              BIGINT       NOT NULL AUTO_INCREMENT,
    phone_number    VARCHAR(20)  NOT NULL,
    full_name       VARCHAR(120) DEFAULT NULL,
    email           VARCHAR(120) DEFAULT NULL,
    password_hash   VARCHAR(100) NOT NULL,
    is_super_admin  TINYINT(1)   NOT NULL DEFAULT 0,
    is_active       TINYINT(1)   NOT NULL DEFAULT 1,
    created_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_admin_phone (phone_number)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci//

-- ============================================================
-- Seed super admin (default password: admin@123 ??? CHANGE IT)
-- ============================================================
INSERT INTO dashboard_admin_users
    (phone_number, full_name, email, password_hash, is_super_admin)
VALUES
    ('9999999999', 'Super Admin', 'admin@karatly.net',
     '$2a$10$kejTFZVMjFIj1GLKVXuW.ei9zexiVF5wu6RmdfLeDUFXrE5T5ggUu', 1)
ON DUPLICATE KEY UPDATE is_super_admin = 1//

-- ============================================================
-- Get admin by phone
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_admin_get_by_phone//

CREATE PROCEDURE sp_dashboard_admin_get_by_phone(IN p_phone VARCHAR(20))
proc: BEGIN
    SELECT id, phone_number, full_name, email, password_hash, is_super_admin, is_active
    FROM dashboard_admin_users
    WHERE phone_number = p_phone
    LIMIT 1;
END//

-- ============================================================
-- Get admin by id
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_admin_get_by_id//

CREATE PROCEDURE sp_dashboard_admin_get_by_id(IN p_id BIGINT)
proc: BEGIN
    SELECT id, phone_number, full_name, email, password_hash, is_super_admin, is_active
    FROM dashboard_admin_users
    WHERE id = p_id
    LIMIT 1;
END//

-- ============================================================
-- Create admin
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_admin_create//

CREATE PROCEDURE sp_dashboard_admin_create(
    IN p_phone VARCHAR(20),
    IN p_name  VARCHAR(120),
    IN p_email VARCHAR(120),
    IN p_hash  VARCHAR(100),
    IN p_super TINYINT(1)
)
proc: BEGIN
    INSERT INTO dashboard_admin_users
        (phone_number, full_name, email, password_hash, is_super_admin)
    VALUES (p_phone, p_name, p_email, p_hash, p_super);
END//

-- ============================================================
-- Update admin password (by id)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_admin_update_password//

CREATE PROCEDURE sp_dashboard_admin_update_password(IN p_id BIGINT, IN p_hash VARCHAR(100))
proc: BEGIN
    UPDATE dashboard_admin_users
    SET password_hash = p_hash
    WHERE id = p_id;
END//

-- ============================================================
-- List admins (no password hash)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_admin_list//

CREATE PROCEDURE sp_dashboard_admin_list()
proc: BEGIN
    SELECT id, phone_number, full_name, email, is_super_admin, is_active,
           DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s') AS created_at
    FROM dashboard_admin_users
    ORDER BY is_super_admin DESC, created_at ASC;
END//

DELIMITER ;

-- ===================== PART 3 =====================
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
                  AND JSON_EXTRACT(o.provider_response_payload, '$.statusCode') != 200
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

