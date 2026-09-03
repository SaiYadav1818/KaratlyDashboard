-- ============================================================
-- Karatly Admin Dashboard - Alerts System
-- Database: sabbpekaratly (MariaDB)
--
-- Table: dashboard_alerts
-- Procs:
--   sp_dashboard_alerts_refresh()    -> scan & insert new open alerts
--   sp_dashboard_alerts_list(p_days, p_category, p_severity, p_status) -> list
--   sp_dashboard_alerts_summary()    -> counts by category + severity
--   sp_dashboard_alerts_acknowledge(p_id, p_admin_id) -> mark acknowledged
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

-- ============================================================
-- TABLE
-- ============================================================
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

-- ============================================================
-- REFRESH: scan all 10 categories, insert new open alerts
-- Idempotent: skips if identical open alert already exists
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_alerts_refresh//

CREATE PROCEDURE sp_dashboard_alerts_refresh()
proc: BEGIN
    -- 1. PAID_NO_GOLD: payment SUCCESS but no Augmont provider_reference
    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT
        'PAID_NO_GOLD', 'critical',
        o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
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
      AND NOT EXISTS (
          SELECT 1 FROM dashboard_alerts a
          WHERE a.category = 'PAID_NO_GOLD' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged')
      );

    -- 2. GOLD_NO_PAYMENT: Augmont purchase exists but payment not SUCCESS
    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT
        'GOLD_NO_PAYMENT', 'critical',
        o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
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
      AND NOT EXISTS (
          SELECT 1 FROM dashboard_alerts a
          WHERE a.category = 'GOLD_NO_PAYMENT' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged')
      );

    -- 3. PENDING_OVER_24H: order not completed/failed/cancelled and older than 24h
    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT
        'PENDING_OVER_24H', 'high',
        o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Order pending for >24 hours (created: ', DATE_FORMAT(o.created_at, '%Y-%m-%d %H:%i'), '). Status: ', COALESCE(o.order_status, 'unknown'), '.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    WHERE o.order_type IN ('digital_purchase', 'digital_sell', 'physical_redemption')
      AND o.order_status NOT IN ('completed', 'confirmed', 'failed', 'cancelled', 'fulfillment_failed')
      AND o.created_at < DATE_SUB(NOW(), INTERVAL 24 HOUR)
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (
          SELECT 1 FROM dashboard_alerts a
          WHERE a.category = 'PENDING_OVER_24H' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged')
      );

    -- 4. PENDING_OVER_72H: upgrade severity for very old pending orders
    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT
        'PENDING_OVER_72H', 'critical',
        o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Order pending for >72 HOURS (created: ', DATE_FORMAT(o.created_at, '%Y-%m-%d %H:%i'), '). Urgent attention needed.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    WHERE o.order_type IN ('digital_purchase', 'digital_sell', 'physical_redemption')
      AND o.order_status NOT IN ('completed', 'confirmed', 'failed', 'cancelled', 'fulfillment_failed')
      AND o.created_at < DATE_SUB(NOW(), INTERVAL 72 HOUR)
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (
          SELECT 1 FROM dashboard_alerts a
          WHERE a.category = 'PENDING_OVER_72H' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged')
      );

    -- 5. MISSING_CASHFREE_WEBHOOK: Cashfree order exists but no payment record
    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT
        'MISSING_CASHFREE_WEBHOOK', 'high',
        o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Cashfree order (', cfo.merchant_order_id, ') created but no payment record received. Webhook may have failed.')
    FROM cashfreepg_orders cfo
    JOIN orders o ON cfo.merchant_order_id = o.merchant_transaction_id
    JOIN client_profile cp ON o.client_id = cp.client_id
    LEFT JOIN cashfreepg_payments cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
    WHERE cfp.id IS NULL
      AND cfo.created_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
      AND NOT EXISTS (
          SELECT 1 FROM dashboard_alerts a
          WHERE a.category = 'MISSING_CASHFREE_WEBHOOK' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged')
      );

    -- 6. MISSING_EASEBUZZ_RECORD: Easebuzz order but no payment_transactions row
    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT
        'MISSING_EASEBUZZ_RECORD', 'high',
        o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Easebuzz order (', o.merchant_transaction_id, ') created but no payment record in payment_transactions.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
    LEFT JOIN cashfreepg_orders cfo ON cfo.merchant_order_id = o.merchant_transaction_id
    WHERE o.order_type IN ('digital_purchase', 'digital_sell')
      AND cfo.id IS NULL
      AND pt.payment_id IS NULL
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
      AND NOT EXISTS (
          SELECT 1 FROM dashboard_alerts a
          WHERE a.category = 'MISSING_EASEBUZZ_RECORD' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged')
      );

    -- 7. AUGMONT_PURCHASE_FAILED: order completed/confirmed but Augmont returned error
    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT
        'AUGMONT_PURCHASE_FAILED', 'critical',
        o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Order marked completed but Augmont purchase failed: ',
               COALESCE(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.message')), o.failure_reason, 'unknown error'), '.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    WHERE o.order_type = 'digital_purchase'
      AND o.order_status IN ('completed', 'confirmed')
      AND o.provider_response_payload IS NOT NULL
      AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.statusCode')), '') NOT IN ('', 'null')
      AND JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.statusCode')) <> '200'
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (
          SELECT 1 FROM dashboard_alerts a
          WHERE a.category = 'AUGMONT_PURCHASE_FAILED' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged')
      );

    -- 8. HIGH_VALUE_PENDING: buy order > 50000 and payment not yet SUCCESS
    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT
        'HIGH_VALUE_PENDING', 'high',
        o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
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
      AND NOT EXISTS (
          SELECT 1 FROM dashboard_alerts a
          WHERE a.category = 'HIGH_VALUE_PENDING' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged')
      );

    -- 9. DUPLICATE_MERCHANT_TXN: same merchant_transaction_id used more than once
    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT
        'DUPLICATE_MERCHANT_TXN', 'critical',
        o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Duplicate merchant_transaction_id detected: ', o.merchant_transaction_id, '. Possible duplicate order.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    JOIN (
        SELECT merchant_transaction_id
        FROM orders
        WHERE merchant_transaction_id IS NOT NULL AND merchant_transaction_id != ''
          AND created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
        GROUP BY merchant_transaction_id
        HAVING COUNT(*) > 1
    ) dup ON o.merchant_transaction_id = dup.merchant_transaction_id
    WHERE o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (
          SELECT 1 FROM dashboard_alerts a
          WHERE a.category = 'DUPLICATE_MERCHANT_TXN' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged')
      );

    -- 10. ZERO_QUANTITY_PURCHASE: buy order completed but quantity = 0
    --     quantity extraction: strip both '' and the literal 'null' string
    --     (some Augmont responses store "quantity":"null")
    INSERT INTO dashboard_alerts (category, severity, order_id, client_id, client_name, client_mobile, amount, message)
    SELECT
        'ZERO_QUANTITY_PURCHASE', 'critical',
        o.order_id, o.client_id, cp.full_name, cp.mobile, o.total_amount,
        CONCAT('Buy order completed but Augmont quantity is 0. Payment of ₹', FORMAT(o.total_amount, 2), ' received but no metal credited.')
    FROM orders o
    JOIN client_profile cp ON o.client_id = cp.client_id
    WHERE o.order_type = 'digital_purchase'
      AND o.order_status IN ('completed', 'confirmed')
      AND CAST(COALESCE(
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
      ) AS DECIMAL(18,4)) = 0
      AND COALESCE(o.total_amount, 0) > 0
      AND o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND NOT EXISTS (
          SELECT 1 FROM dashboard_alerts a
          WHERE a.category = 'ZERO_QUANTITY_PURCHASE' AND a.order_id = o.order_id AND a.status IN ('open','acknowledged')
      );

    -- Return summary counts after refresh
    SELECT category, severity, COUNT(*) AS cnt
    FROM dashboard_alerts
    WHERE status = 'open'
    GROUP BY category, severity
    ORDER BY FIELD(severity, 'critical', 'high', 'medium'), category;
END//

-- ============================================================
-- LIST: paginated with filters
-- ============================================================
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

    SELECT
        a.id,
        a.category,
        a.severity,
        a.order_id,
        a.client_id,
        a.client_name,
        a.client_mobile,
        a.amount,
        a.message,
        a.status,
        a.acknowledged_by,
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
    ORDER BY FIELD(a.severity, 'critical', 'high', 'medium') ASC,
             a.created_at DESC;
END//

-- ============================================================
-- SUMMARY: counts by category + severity (for sidebar badges)
-- ============================================================
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

-- ============================================================
-- ACKNOWLEDGE
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_alerts_acknowledge//

CREATE PROCEDURE sp_dashboard_alerts_acknowledge(
    IN p_id       BIGINT,
    IN p_admin_id BIGINT
)
proc: BEGIN
    UPDATE dashboard_alerts
    SET status = 'acknowledged',
        acknowledged_by = p_admin_id,
        acknowledged_at = NOW()
    WHERE id = p_id AND status = 'open';
END//

-- ============================================================
-- RESOLVE
-- ============================================================
DROP PROCEDURE IF EXISTS sp_dashboard_alerts_resolve//

CREATE PROCEDURE sp_dashboard_alerts_resolve(
    IN p_id       BIGINT,
    IN p_admin_id BIGINT,
    IN p_note     TEXT
)
proc: BEGIN
    UPDATE dashboard_alerts
    SET status = 'resolved',
        resolved_by = p_admin_id,
        resolved_at = NOW(),
        resolve_note = p_note
    WHERE id = p_id AND status IN ('open', 'acknowledged');
END//

DELIMITER ;
