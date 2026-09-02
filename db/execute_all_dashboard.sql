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
--   PART 4 : alerts system (table dashboard_alerts + sp_dashboard_alerts_*)
--   PART 5 : order audit trail (sp_dashboard_order_audit)
--   PART 6 : MIS overview (sp_dashboard_mis_overview/aum/coupons)
--
-- NOTE:
--   * Every proc uses DROP PROCEDURE IF EXISTS -> SAFE to re-run.
--   * PART 2 creates table dashboard_admin_users and seeds a
--     super admin: phone 9999999999 / password admin@123
--     (CHANGE THIS PASSWORD AFTER FIRST LOGIN).
--   * PART 4 creates table dashboard_alerts for the alerts system.
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

-- ===================== PART 5 =====================
-- ============================================================
-- Karatly Admin Dashboard - Order Audit Trail
-- Database: sabbpekaratly (MariaDB)
--
-- Procs:
--   sp_dashboard_order_audit(p_merchant_txn_id) -> full audit for one order
--     joins orders + cashfreepg_orders + cashfreepg_payments + cashfreepg_webhooks
--     returns: order details, CF order, CF payment, CF webhook, Easebuzz, Augmont response
-- ============================================================

DELIMITER //

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

        cfo.id AS cf_order_row_id,
        cfo.sabbpe_order_id AS cf_sabbpe_order_id,
        cfo.provider_order_id AS cf_provider_order_id,
        cfo.order_status AS cf_order_status,
        DATE_FORMAT(cfo.created_at, '%Y-%m-%d %H:%i:%s') AS cf_order_date,

        cfp.id AS cf_payment_row_id,
        cfp.cf_payment_id,
        cfp.payment_status AS cf_payment_status,
        cfp.payment_method,
        cfp.bank_reference AS cf_rrn,
        DATE_FORMAT(cfp.created_at, '%Y-%m-%d %H:%i:%s') AS cf_payment_date,

        cfw.id AS cf_webhook_row_id,
        cfw.webhook_type,
        cfw.payment_status AS webhook_payment_status,
        cfw.processed AS webhook_processed,
        DATE_FORMAT(COALESCE(cfw.processed_time, cfw.created_at), '%Y-%m-%d %H:%i:%s') AS webhook_date,

        pt.payment_id AS easebuzz_payment_id,
        pt.payment_status AS easebuzz_payment_status,

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

-- ===================== PART 4 =====================
-- ============================================================
-- Karatly Admin Dashboard - Alerts System
-- Database: sabbpekaratly (MariaDB)
--
-- Table: dashboard_alerts
-- Procs:
--   sp_dashboard_alerts_refresh()                    -> scan & insert new open alerts
--   sp_dashboard_alerts_list(p_days,p_cat,p_sev,p_st)-> list with filters
--   sp_dashboard_alerts_summary()                    -> counts by category + severity
--   sp_dashboard_alerts_acknowledge(p_id, p_admin_id)-> mark acknowledged
--   sp_dashboard_alerts_resolve(p_id, p_admin_id, p_note) -> mark resolved
--
-- Scan categories (10):
--   PAID_NO_GOLD              - payment SUCCESS but no Augmont purchase
--   GOLD_NO_PAYMENT           - Augmont purchase exists but payment not SUCCESS
--   PENDING_OVER_24H          - order pending > 24 hours
--   PENDING_OVER_72H          - order pending > 72 hours
--   MISSING_CASHFREE_WEBHOOK  - Cashfree order created but no payment record
--   MISSING_EASEBUZZ_RECORD   - Easebuzz order but no payment_transactions row
--   AUGMONT_PURCHASE_FAILED   - order completed but Augmont error in response
--   HIGH_VALUE_PENDING        - buy order > 50000 and payment not SUCCESS
--   DUPLICATE_MERCHANT_TXN    - same merchant_transaction_id used more than once
--   ZERO_QUANTITY_PURCHASE    - buy order completed but quantity = 0
-- ============================================================

DELIMITER //

CREATE TABLE IF NOT EXISTS dashboard_alerts (
    id              BIGINT       NOT NULL AUTO_INCREMENT,
    category        VARCHAR(50)  NOT NULL,
    severity        VARCHAR(10)  NOT NULL DEFAULT 'high',
    order_id        VARCHAR(64)  DEFAULT NULL,
    client_id       VARCHAR(64)  DEFAULT NULL,
    client_name     VARCHAR(120) DEFAULT NULL,
    client_mobile   VARCHAR(20)  DEFAULT NULL,
    amount          DECIMAL(18,2) DEFAULT NULL,
    message         TEXT         NOT NULL,
    status          VARCHAR(20)  NOT NULL DEFAULT 'open',
    acknowledged_by BIGINT       DEFAULT NULL,
    acknowledged_at TIMESTAMP    NULL     DEFAULT NULL,
    resolved_by     BIGINT       DEFAULT NULL,
    resolved_at     TIMESTAMP    NULL     DEFAULT NULL,
    resolve_note    TEXT         DEFAULT NULL,
    created_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX idx_alerts_status (status),
    INDEX idx_alerts_category (category),
    INDEX idx_alerts_severity (severity),
    INDEX idx_alerts_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci//

DROP PROCEDURE IF EXISTS sp_dashboard_alerts_refresh//

CREATE PROCEDURE sp_dashboard_alerts_refresh()
proc: BEGIN
    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT 'PAID_NO_GOLD', 'critical', o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Payment successful (₹', FORMAT(o.total_amount, 2), ') but no gold credited. Augmont purchase missing.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
    LEFT JOIN cashfreepg_orders cfo ON cfo.merchant_order_id = o.merchant_transaction_id
    LEFT JOIN cashfreepg_payments cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
    WHERE o.order_type = 'digital_purchase'
      AND UPPER(COALESCE(pt.payment_status, cfp.payment_status, '')) = 'SUCCESS'
      AND (o.provider_reference IS NULL OR TRIM(o.provider_reference) = '')
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (SELECT 1 FROM dashboard_alerts a WHERE a.category = 'PAID_NO_GOLD' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged'));

    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT 'GOLD_NO_PAYMENT', 'critical', o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Gold credited (Augmont ref: ', o.provider_reference, ') but payment status is not SUCCESS.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
    LEFT JOIN cashfreepg_orders cfo ON cfo.merchant_order_id = o.merchant_transaction_id
    LEFT JOIN cashfreepg_payments cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
    WHERE o.order_type = 'digital_purchase'
      AND (o.provider_reference IS NOT NULL AND TRIM(o.provider_reference) <> '')
      AND UPPER(COALESCE(pt.payment_status, cfp.payment_status, '')) NOT IN ('SUCCESS', '')
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (SELECT 1 FROM dashboard_alerts a WHERE a.category = 'GOLD_NO_PAYMENT' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged'));

    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT 'PENDING_OVER_24H', 'high', o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Order pending for >24 hours (created: ', DATE_FORMAT(o.created_at, '%Y-%m-%d %H:%i'), '). Status: ', COALESCE(o.order_status, 'unknown'), '.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    WHERE o.order_type IN ('digital_purchase', 'digital_sell', 'physical_redemption')
      AND o.order_status NOT IN ('completed', 'confirmed', 'failed', 'cancelled', 'fulfillment_failed')
      AND o.created_at < DATE_SUB(NOW(), INTERVAL 24 HOUR)
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (SELECT 1 FROM dashboard_alerts a WHERE a.category = 'PENDING_OVER_24H' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged'));

    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT 'PENDING_OVER_72H', 'critical', o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Order pending for >72 HOURS (created: ', DATE_FORMAT(o.created_at, '%Y-%m-%d %H:%i'), '). Urgent attention needed.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    WHERE o.order_type IN ('digital_purchase', 'digital_sell', 'physical_redemption')
      AND o.order_status NOT IN ('completed', 'confirmed', 'failed', 'cancelled', 'fulfillment_failed')
      AND o.created_at < DATE_SUB(NOW(), INTERVAL 72 HOUR)
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (SELECT 1 FROM dashboard_alerts a WHERE a.category = 'PENDING_OVER_72H' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged'));

    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT 'MISSING_CASHFREE_WEBHOOK', 'high', o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Cashfree order (', cfo.merchant_order_id, ') created but no payment record received. Webhook may have failed.')
    FROM cashfreepg_orders cfo
    JOIN orders o ON cfo.merchant_order_id = o.merchant_transaction_id
    JOIN client_profile cp ON o.client_id = cp.client_id
    LEFT JOIN cashfreepg_payments cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
    WHERE cfp.id IS NULL
      AND cfo.created_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
      AND NOT EXISTS (SELECT 1 FROM dashboard_alerts a WHERE a.category = 'MISSING_CASHFREE_WEBHOOK' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged'));

    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT 'MISSING_EASEBUZZ_RECORD', 'high', o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Easebuzz order (', o.merchant_transaction_id, ') created but no payment record in payment_transactions.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
    LEFT JOIN cashfreepg_orders cfo ON cfo.merchant_order_id = o.merchant_transaction_id
    WHERE o.order_type IN ('digital_purchase', 'digital_sell')
      AND cfo.id IS NULL
      AND pt.payment_id IS NULL
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
      AND NOT EXISTS (SELECT 1 FROM dashboard_alerts a WHERE a.category = 'MISSING_EASEBUZZ_RECORD' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged'));

    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT 'AUGMONT_PURCHASE_FAILED', 'critical', o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Order marked completed but Augmont purchase failed: ', COALESCE(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.message')), o.failure_reason, 'unknown error'), '.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    WHERE o.order_type = 'digital_purchase'
      AND o.order_status IN ('completed', 'confirmed')
      AND o.provider_response_payload IS NOT NULL
      AND (JSON_EXTRACT(o.provider_response_payload, '$.statusCode') IS NOT NULL AND JSON_EXTRACT(o.provider_response_payload, '$.statusCode') != 200)
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (SELECT 1 FROM dashboard_alerts a WHERE a.category = 'AUGMONT_PURCHASE_FAILED' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged'));

    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT 'HIGH_VALUE_PENDING', 'high', o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('High-value buy order (₹', FORMAT(o.total_amount, 2), ') pending payment confirmation. Needs manual check.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
    LEFT JOIN cashfreepg_orders cfo ON cfo.merchant_order_id = o.merchant_transaction_id
    LEFT JOIN cashfreepg_payments cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
    WHERE o.order_type = 'digital_purchase'
      AND COALESCE(o.total_amount, 0) > 50000
      AND UPPER(COALESCE(pt.payment_status, cfp.payment_status, '')) NOT IN ('SUCCESS', 'FAILED')
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
      AND NOT EXISTS (SELECT 1 FROM dashboard_alerts a WHERE a.category = 'HIGH_VALUE_PENDING' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged'));

    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT 'DUPLICATE_MERCHANT_TXN', 'critical', o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Duplicate merchant_transaction_id detected: ', o.merchant_transaction_id, '. Possible duplicate order.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    JOIN (SELECT merchant_transaction_id FROM orders WHERE merchant_transaction_id IS NOT NULL AND merchant_transaction_id != '' AND created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY) GROUP BY merchant_transaction_id HAVING COUNT(*) > 1) dup ON o.merchant_transaction_id = dup.merchant_transaction_id
    WHERE o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (SELECT 1 FROM dashboard_alerts a WHERE a.category = 'DUPLICATE_MERCHANT_TXN' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged'));

    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT 'ZERO_QUANTITY_PURCHASE', 'critical', o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Buy order completed but Augmont quantity is 0. Payment of ₹', FORMAT(o.total_amount, 2), ' received but no metal credited.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    WHERE o.order_type = 'digital_purchase'
      AND o.order_status IN ('completed', 'confirmed')
      AND CAST(COALESCE(
          NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), ''),
          NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), 'null'),
          NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.quantity')), ''),
          NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.quantity')), 'null'),
          '0'
      ) AS DECIMAL(18,4)) = 0
      AND COALESCE(o.total_amount, 0) > 0
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (SELECT 1 FROM dashboard_alerts a WHERE a.category = 'ZERO_QUANTITY_PURCHASE' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged'));

    SELECT category, severity, COUNT(*) AS cnt
    FROM dashboard_alerts WHERE status = 'open'
    GROUP BY category, severity
    ORDER BY FIELD(severity, 'critical', 'high', 'medium'), category;
END//

DROP PROCEDURE IF EXISTS sp_dashboard_alerts_list//

CREATE PROCEDURE sp_dashboard_alerts_list(
    IN p_days     INT,
    IN p_category VARCHAR(50),
    IN p_severity VARCHAR(10),
    IN p_status   VARCHAR(20)
)
proc: BEGIN
    DECLARE v_since DATE;
    SET v_since = DATE_SUB(CURDATE(), INTERVAL p_days DAY);

    SELECT a.id, a.category, a.severity, a.order_id, a.client_id, a.client_name, a.client_mobile,
        a.amount, a.message, a.status, a.acknowledged_by,
        DATE_FORMAT(a.acknowledged_at, '%Y-%m-%d %H:%i:%s') AS acknowledged_at,
        a.resolved_by,
        DATE_FORMAT(a.resolved_at, '%Y-%m-%d %H:%i:%s') AS resolved_at,
        a.resolve_note,
        DATE_FORMAT(a.created_at, '%Y-%m-%d %H:%i:%s') AS created_at,
        DATE_FORMAT(a.updated_at, '%Y-%m-%d %H:%i:%s') AS updated_at
    FROM dashboard_alerts a
    WHERE a.created_at >= v_since
      AND (p_category IS NULL OR p_category = '' OR a.category = p_category)
      AND (p_severity IS NULL OR p_severity = '' OR a.severity = p_severity)
      AND (p_status   IS NULL OR p_status   = '' OR p_status = 'ALL' OR a.status = p_status)
    ORDER BY FIELD(a.severity, 'critical', 'high', 'medium') ASC, a.created_at DESC;
END//

DROP PROCEDURE IF EXISTS sp_dashboard_alerts_summary//

CREATE PROCEDURE sp_dashboard_alerts_summary()
proc: BEGIN
    SELECT
        COUNT(*) AS total_open,
        SUM(CASE WHEN severity = 'critical' THEN 1 ELSE 0 END) AS critical,
        SUM(CASE WHEN severity = 'high'     THEN 1 ELSE 0 END) AS high_count,
        SUM(CASE WHEN severity = 'medium'   THEN 1 ELSE 0 END) AS medium_count,
        (SELECT COUNT(*) FROM dashboard_alerts WHERE status = 'acknowledged') AS acknowledged,
        (SELECT COUNT(*) FROM dashboard_alerts WHERE status = 'resolved') AS resolved_total
    FROM dashboard_alerts
    WHERE status = 'open';
END//

DROP PROCEDURE IF EXISTS sp_dashboard_alerts_acknowledge//

CREATE PROCEDURE sp_dashboard_alerts_acknowledge(IN p_id BIGINT, IN p_admin_id BIGINT)
proc: BEGIN
    UPDATE dashboard_alerts SET status = 'acknowledged', acknowledged_by = p_admin_id, acknowledged_at = NOW()
    WHERE id = p_id AND status = 'open';
END//

DROP PROCEDURE IF EXISTS sp_dashboard_alerts_resolve//

CREATE PROCEDURE sp_dashboard_alerts_resolve(IN p_id BIGINT, IN p_admin_id BIGINT, IN p_note TEXT)
proc: BEGIN
    UPDATE dashboard_alerts SET status = 'resolved', resolved_by = p_admin_id, resolved_at = NOW(), resolve_note = p_note
    WHERE id = p_id AND status IN ('open', 'acknowledged');
END//

DELIMITER ;

-- ===================== PART 6 =====================
-- ============================================================
-- Karatly Admin Dashboard - MIS Overview
-- Database: sabbpekaratly (MariaDB)
--
-- Procs:
--   sp_dashboard_mis_overview()  -> GMV + Transaction Count + Users + Metals + Coupons
--   sp_dashboard_mis_aum()       -> Metal Balance (AUM) metrics
--   sp_dashboard_mis_coupons()   -> Coupon usage metrics
-- ============================================================

DELIMITER //

DROP PROCEDURE IF EXISTS sp_dashboard_mis_overview//

CREATE PROCEDURE sp_dashboard_mis_overview()
proc: BEGIN
    DECLARE v_ytd_start DATE;
    DECLARE v_mtd_start DATE;
    DECLARE v_ftd_start DATE;
    DECLARE v_today DATE;

    SET v_today = CURDATE();
    SET v_ytd_start = CONCAT(YEAR(v_today), '-01-01');
    SET v_mtd_start = CONCAT(YEAR(v_today), '-', MONTH(v_today), '-01');
    SET v_ftd_start = v_today;

    SELECT
        COALESCE(ytd.ytd_count, 0) AS gmv_ytd_count,
        COALESCE(ytd.ytd_value, 0) AS gmv_ytd_value,
        COALESCE(mtd.mtd_count, 0) AS gmv_mtd_count,
        COALESCE(mtd.mtd_value, 0) AS gmv_mtd_value,
        COALESCE(ftd.ftd_count, 0) AS gmv_ftd_count,
        COALESCE(ftd.ftd_value, 0) AS gmv_ftd_value,
        COALESCE(txn.txn_total, 0) AS txn_mtd_total,
        COALESCE(txn.txn_success, 0) AS txn_mtd_success,
        COALESCE(txn.txn_failed, 0) AS txn_mtd_failed,
        COALESCE(usr.unique_users, 0) AS unique_users,
        COALESCE(usr.repeat_users, 0) AS repeat_users,
        COALESCE(usr.flagged_users, 0) AS flagged_users,
        COALESCE(met.gold_grams, 0) AS gold_grams,
        COALESCE(met.gold_value, 0) AS gold_value,
        COALESCE(met.silver_grams, 0) AS silver_grams,
        COALESCE(met.silver_value, 0) AS silver_value,
        COALESCE(diam.diamond_carats, 0) AS diamond_carats,
        COALESCE(diam.diamond_value, 0) AS diamond_value,
        COALESCE(diam.diamond_count, 0) AS diamond_count,
        CASE WHEN COALESCE(ytd.ytd_value, 0) > 0 THEN ROUND(COALESCE(met.gold_value, 0) / ytd.ytd_value * 100, 1) ELSE 0 END AS gold_pct_gmv,
        CASE WHEN COALESCE(ytd.ytd_value, 0) > 0 THEN ROUND(COALESCE(met.silver_value, 0) / ytd.ytd_value * 100, 1) ELSE 0 END AS silver_pct_gmv,
        CASE WHEN COALESCE(ytd.ytd_value, 0) > 0 THEN ROUND(COALESCE(diam.diamond_value, 0) / ytd.ytd_value * 100, 1) ELSE 0 END AS diamond_pct_gmv,
        COALESCE(cpn.coupon_count, 0) AS coupons_redeemed_count,
        COALESCE(cpn.coupon_value, 0) AS coupons_redeemed_value
    FROM (SELECT 1) dummy
    LEFT JOIN (SELECT COUNT(*) AS ytd_count, SUM(COALESCE(o.total_amount, 0)) AS ytd_value FROM orders o WHERE o.order_type IN ('digital_purchase','digital_sell','physical_redemption','diamond_purchase') AND o.created_at >= v_ytd_start) ytd ON 1=1
    LEFT JOIN (SELECT COUNT(*) AS mtd_count, SUM(COALESCE(o.total_amount, 0)) AS mtd_value FROM orders o WHERE o.order_type IN ('digital_purchase','digital_sell','physical_redemption','diamond_purchase') AND o.created_at >= v_mtd_start) mtd ON 1=1
    LEFT JOIN (SELECT COUNT(*) AS ftd_count, SUM(COALESCE(o.total_amount, 0)) AS ftd_value FROM orders o WHERE o.order_type IN ('digital_purchase','digital_sell','physical_redemption','diamond_purchase') AND o.created_at >= v_ftd_start) ftd ON 1=1
    LEFT JOIN (
        SELECT COUNT(*) AS txn_total,
            SUM(CASE WHEN UPPER(COALESCE(pt.payment_status, cfp.payment_status, '')) = 'SUCCESS' THEN 1 ELSE 0 END) AS txn_success,
            SUM(CASE WHEN UPPER(COALESCE(pt.payment_status, cfp.payment_status, '')) = 'FAILED' THEN 1 ELSE 0 END) AS txn_failed
        FROM orders o
        LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
        LEFT JOIN cashfreepg_orders cfo ON cfo.merchant_order_id = o.merchant_transaction_id
        LEFT JOIN cashfreepg_payments cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
        WHERE o.order_type IN ('digital_purchase','digital_sell','physical_redemption','diamond_purchase') AND o.created_at >= v_mtd_start
    ) txn ON 1=1
    LEFT JOIN (
        SELECT COUNT(DISTINCT cp.client_id) AS unique_users,
            SUM(CASE WHEN o.client_order_count > 1 THEN 1 ELSE 0 END) AS repeat_users,
            (SELECT COUNT(*) FROM client_profile WHERE kyc_status = 'rejected' OR kyc_status = 'failed') AS flagged_users
        FROM client_profile cp
        LEFT JOIN (SELECT client_id, COUNT(*) AS client_order_count FROM orders WHERE order_type IN ('digital_purchase','digital_sell','physical_redemption','diamond_purchase') GROUP BY client_id) o ON cp.client_id = o.client_id
    ) usr ON 1=1
    LEFT JOIN (
        SELECT
            SUM(CASE WHEN COALESCE(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')), JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')), 'gold') = 'gold' AND o.order_status IN ('completed','confirmed') THEN CAST(COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), ''), NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.quantity')), ''), '0') AS DECIMAL(18,4)) ELSE 0 END) AS gold_grams,
            SUM(CASE WHEN COALESCE(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')), JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')), 'gold') = 'gold' THEN COALESCE(o.total_amount, 0) ELSE 0 END) AS gold_value,
            SUM(CASE WHEN COALESCE(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')), JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')), 'gold') = 'silver' AND o.order_status IN ('completed','confirmed') THEN CAST(COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), ''), NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.quantity')), ''), '0') AS DECIMAL(18,4)) ELSE 0 END) AS silver_grams,
            SUM(CASE WHEN COALESCE(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')), JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')), 'gold') = 'silver' THEN COALESCE(o.total_amount, 0) ELSE 0 END) AS silver_value
        FROM orders o WHERE o.order_type = 'digital_purchase' AND o.created_at >= v_ytd_start
    ) met ON 1=1
    LEFT JOIN (
        SELECT COUNT(*) AS diamond_count, COALESCE(SUM(o.total_amount), 0) AS diamond_value, COALESCE(SUM(di.weight), 0) AS diamond_carats
        FROM orders o
        LEFT JOIN JSON_TABLE(o.pricing_snapshot, '$.items[*]' COLUMNS (productId VARCHAR(36) PATH '$.productId')) jt ON TRUE
        LEFT JOIN diamond_inventory di ON di.id = jt.productId
        WHERE o.order_type = 'diamond_purchase' AND o.order_status IN ('completed', 'confirmed') AND o.created_at >= v_ytd_start
    ) diam ON 1=1
    LEFT JOIN (SELECT COUNT(*) AS coupon_count, SUM(cu.discount_amount) AS coupon_value FROM coupon_usage cu WHERE cu.used_at >= v_ytd_start) cpn ON 1=1;
END//

DROP PROCEDURE IF EXISTS sp_dashboard_mis_aum//

CREATE PROCEDURE sp_dashboard_mis_aum()
proc: BEGIN
    DECLARE v_ytd_start DATE;
    DECLARE v_mtd_start DATE;
    DECLARE v_today DATE;
    DECLARE v_total_users INT;

    SET v_today = CURDATE();
    SET v_ytd_start = CONCAT(YEAR(v_today), '-01-01');
    SET v_mtd_start = CONCAT(YEAR(v_today), '-', MONTH(v_today), '-01');
    SELECT COUNT(*) INTO v_total_users FROM client_profile;

    SELECT
        COALESCE(SUM(CASE WHEN o.created_at >= v_ytd_start THEN COALESCE(o.total_amount, 0) ELSE 0 END), 0) AS aum_ytd,
        COALESCE(SUM(CASE WHEN o.created_at >= v_mtd_start THEN COALESCE(o.total_amount, 0) ELSE 0 END), 0) AS aum_mtd,
        COALESCE(SUM(CASE WHEN DATE(o.created_at) = v_today THEN COALESCE(o.total_amount, 0) ELSE 0 END), 0) AS aum_ftd,
        CASE WHEN DAY(v_today) > 0 THEN ROUND(COALESCE(SUM(CASE WHEN o.created_at >= v_mtd_start THEN COALESCE(o.total_amount, 0) ELSE 0 END), 0) / DAY(v_today) * 30, 0) ELSE 0 END AS aum_run_rate_monthly,
        CASE WHEN v_total_users > 0 THEN ROUND(COALESCE(SUM(COALESCE(o.total_amount, 0)), 0) / v_total_users, 0) ELSE 0 END AS avg_holding_per_user,
        CASE WHEN COALESCE(SUM(CASE WHEN o.order_type = 'digital_purchase' THEN COALESCE(o.total_amount, 0) ELSE 0 END), 0) > 0
             THEN ROUND(COALESCE(SUM(CASE WHEN o.order_type = 'digital_sell' THEN COALESCE(o.total_amount, 0) ELSE 0 END), 0) / COALESCE(SUM(CASE WHEN o.order_type = 'digital_purchase' THEN COALESCE(o.total_amount, 0) ELSE 0 END), 1) * 100, 1)
             ELSE 0 END AS redemption_rate_pct
    FROM orders o
    WHERE o.order_type IN ('digital_purchase', 'digital_sell') AND o.order_status IN ('completed', 'confirmed');
END//

DROP PROCEDURE IF EXISTS sp_dashboard_mis_coupons//

CREATE PROCEDURE sp_dashboard_mis_coupons()
proc: BEGIN
    DECLARE v_ytd_start DATE;
    DECLARE v_mtd_start DATE;
    SET v_ytd_start = CONCAT(YEAR(CURDATE()), '-01-01');
    SET v_mtd_start = CONCAT(YEAR(CURDATE()), '-', MONTH(CURDATE()), '-01');

    SELECT
        COALESCE(SUM(CASE WHEN cu.used_at >= v_ytd_start THEN 1 ELSE 0 END), 0) AS coupons_ytd_count,
        COALESCE(SUM(CASE WHEN cu.used_at >= v_ytd_start THEN cu.discount_amount ELSE 0 END), 0) AS coupons_ytd_value,
        COALESCE(SUM(CASE WHEN cu.used_at >= v_mtd_start THEN 1 ELSE 0 END), 0) AS coupons_mtd_count,
        COALESCE(SUM(CASE WHEN cu.used_at >= v_mtd_start THEN cu.discount_amount ELSE 0 END), 0) AS coupons_mtd_value
    FROM coupon_usage cu;
END//

DROP PROCEDURE IF EXISTS sp_dashboard_mis_watchlist//

CREATE PROCEDURE sp_dashboard_mis_watchlist()
proc: BEGIN
    DECLARE v_since DATETIME;
    SET v_since = DATE_SUB(NOW(), INTERVAL 30 DAY);

    WITH rate_rows AS (
        SELECT
            r.metal_type,
            r.rate_per_unit AS buy_rate,
            CAST(JSON_UNQUOTE(JSON_EXTRACT(r.api_response_payload,
                CONCAT('$.result.data.rates.', IF(r.metal_type = 'gold', 'gSell', 'sSell')))) AS DECIMAL(18,2)) AS sell_rate
        FROM metal_price_cache r
        JOIN (
            SELECT metal_type, MAX(fetched_at) AS last_fetched
            FROM metal_price_cache
            WHERE provider = 'AUGMONT' AND metal_type IN ('gold','silver')
            GROUP BY metal_type
        ) latest ON r.provider = 'AUGMONT' AND r.metal_type = latest.metal_type AND r.fetched_at = latest.last_fetched
    ),
    spreads AS (
        SELECT metal_type, buy_rate, sell_rate,
               ROUND((buy_rate - sell_rate) / buy_rate * 100, 1) AS spread_pct
        FROM rate_rows
        WHERE sell_rate IS NOT NULL AND buy_rate > 0
    ),
    volumes AS (
        SELECT metal, SUM(grams) AS grams FROM (
            SELECT COALESCE(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')), JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')), 'gold') AS metal,
                   CAST(COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), ''), NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.quantity')), ''), '0') AS DECIMAL(18,4)) AS grams
            FROM orders o
            WHERE o.order_type = 'digital_purchase' AND o.order_status IN ('completed','confirmed') AND o.created_at >= v_since
            UNION ALL
            SELECT 'diamond', di.weight
            FROM orders o
            LEFT JOIN JSON_TABLE(o.pricing_snapshot, '$.items[*]' COLUMNS (productId VARCHAR(36) PATH '$.productId')) jt ON TRUE
            LEFT JOIN diamond_inventory di ON di.id = jt.productId
            WHERE o.order_type = 'diamond_purchase' AND o.order_status IN ('completed','confirmed') AND o.created_at >= v_since
        ) v
        GROUP BY metal
    )
    SELECT
        (SELECT metal_type FROM spreads ORDER BY spread_pct DESC LIMIT 1) AS high_margin_metal,
        (SELECT spread_pct  FROM spreads ORDER BY spread_pct DESC LIMIT 1) AS high_margin_pct,
        (SELECT metal_type FROM spreads ORDER BY spread_pct ASC  LIMIT 1) AS low_margin_metal,
        (SELECT spread_pct  FROM spreads ORDER BY spread_pct ASC  LIMIT 1) AS low_margin_pct,
        (SELECT metal FROM volumes ORDER BY grams DESC LIMIT 1) AS high_volume_metal,
        (SELECT grams FROM volumes ORDER BY grams DESC LIMIT 1) AS high_volume_grams,
        (SELECT GROUP_CONCAT(metal ORDER BY metal SEPARATOR ', ') FROM (
             SELECT 'gold' AS metal UNION SELECT 'silver' UNION SELECT 'platinum' UNION SELECT 'pearl' UNION SELECT 'diamond'
         ) allmetals
         WHERE metal NOT IN (SELECT metal FROM volumes WHERE grams > 0)) AS zero_volume_metals;
END//

DELIMITER ;

