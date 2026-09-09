-- ============================================================
-- PART 8 : Gold Fulfillment Requests (Level 1 → Level 2 flow)
-- ============================================================
-- Level 1 admin sees unfulfilled orders → sends request to Level 2
-- Level 2 admin reviews → approves or rejects
-- ============================================================

-- Table: gold_fulfillment_requests
CREATE TABLE IF NOT EXISTS gold_fulfillment_requests (
    id              BIGINT       NOT NULL AUTO_INCREMENT,
    sabbpe_order_id VARCHAR(64)  NOT NULL,
    customer_id     VARCHAR(64)  NOT NULL,
    customer_name   VARCHAR(200) DEFAULT NULL,
    customer_mobile VARCHAR(20)  DEFAULT NULL,
    order_amount    DECIMAL(18,2) NOT NULL,
    lock_price      VARCHAR(20)  DEFAULT NULL COMMENT 'Locked rate from payment snapshot',
    block_id        VARCHAR(64)  DEFAULT NULL COMMENT 'Block ID from payment snapshot',
    metal_type      VARCHAR(20)  DEFAULT 'gold' COMMENT 'gold or silver',
    merchant_order_id VARCHAR(64) DEFAULT NULL COMMENT 'Merchant order ID for Augmont buy',
    created_by      BIGINT       NOT NULL COMMENT 'Level 1 admin who created the request',
    assigned_to     BIGINT       DEFAULT NULL COMMENT 'Level 2 admin who acts on it',
    status          VARCHAR(20)  NOT NULL DEFAULT 'PENDING' COMMENT 'PENDING | APPROVED | REJECTED | PROCESSED',
    level1_note     TEXT         DEFAULT NULL COMMENT 'Note from Level 1 admin',
    level2_note     TEXT         DEFAULT NULL COMMENT 'Note from Level 2 admin',
    retry_count     INT          NOT NULL DEFAULT 0 COMMENT 'Number of retry attempts',
    last_retry_at   DATETIME     DEFAULT NULL,
    created_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_status (status),
    KEY idx_order (sabbpe_order_id),
    KEY idx_created_by (created_by),
    KEY idx_assigned_to (assigned_to)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci//

DELIMITER ;

-- ============================================================
-- 1. Level 1: Create a fulfillment request (send to Level 2)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_fulfillment_request_create//

CREATE PROCEDURE sp_fulfillment_request_create(
    IN p_sabbpe_order_id VARCHAR(64),
    IN p_customer_id     VARCHAR(64),
    IN p_customer_name   VARCHAR(200),
    IN p_customer_mobile VARCHAR(20),
    IN p_order_amount    DECIMAL(18,2),
    IN p_lock_price      VARCHAR(20),
    IN p_block_id        VARCHAR(64),
    IN p_metal_type      VARCHAR(20),
    IN p_merchant_order_id VARCHAR(64),
    IN p_created_by      BIGINT,
    IN p_level1_note     TEXT
)
BEGIN
    DECLARE v_exists INT DEFAULT 0;

    SELECT COUNT(*) INTO v_exists
    FROM gold_fulfillment_requests
    WHERE sabbpe_order_id = p_sabbpe_order_id
      AND status IN ('PENDING', 'APPROVED');

    IF v_exists > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A pending or approved request already exists for this order';
    ELSE
        INSERT INTO gold_fulfillment_requests
            (sabbpe_order_id, customer_id, customer_name, customer_mobile,
             order_amount, lock_price, block_id, metal_type, merchant_order_id,
             created_by, level1_note)
        VALUES
            (p_sabbpe_order_id, p_customer_id, p_customer_name, p_customer_mobile,
             p_order_amount, p_lock_price, p_block_id, p_metal_type, p_merchant_order_id,
             p_created_by, p_level1_note);

        SELECT LAST_INSERT_ID() AS request_id;
    END IF;
END//

-- ============================================================
-- 2. Level 1: List my requests (created by me)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_fulfillment_request_list_mine//

CREATE PROCEDURE sp_fulfillment_request_list_mine(
    IN p_admin_id BIGINT
)
BEGIN
    SELECT
        r.id,
        r.sabbpe_order_id,
        r.customer_id,
        r.customer_name,
        r.customer_mobile,
        r.order_amount,
        r.lock_price,
        r.block_id,
        r.metal_type,
        r.merchant_order_id,
        r.status,
        r.level1_note,
        r.level2_note,
        r.retry_count,
        DATE_FORMAT(r.last_retry_at, '%Y-%m-%d %H:%i:%s') AS last_retry_at,
        a.fullName AS assigned_to_name,
        DATE_FORMAT(r.created_at, '%Y-%m-%d %H:%i:%s') AS created_at,
        DATE_FORMAT(r.updated_at, '%Y-%m-%d %H:%i:%s') AS updated_at
    FROM gold_fulfillment_requests r
    LEFT JOIN dashboard_admin_users a ON a.id = r.assigned_to
    WHERE r.created_by = p_admin_id
    ORDER BY r.created_at DESC;
END//

-- ============================================================
-- 3. Level 2: List pending requests (all or assigned to me)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_fulfillment_request_list_pending//

CREATE PROCEDURE sp_fulfillment_request_list_pending(
    IN p_admin_id BIGINT
)
BEGIN
    SELECT
        r.id,
        r.sabbpe_order_id,
        r.customer_id,
        r.customer_name,
        r.customer_mobile,
        r.order_amount,
        r.lock_price,
        r.block_id,
        r.metal_type,
        r.merchant_order_id,
        r.status,
        r.level1_note,
        r.level2_note,
        r.retry_count,
        DATE_FORMAT(r.last_retry_at, '%Y-%m-%d %H:%i:%s') AS last_retry_at,
        cr.fullName AS created_by_name,
        DATE_FORMAT(r.created_at, '%Y-%m-%d %H:%i:%s') AS created_at,
        DATE_FORMAT(r.updated_at, '%Y-%m-%d %H:%i:%s') AS updated_at
    FROM gold_fulfillment_requests r
    LEFT JOIN dashboard_admin_users cr ON cr.id = r.created_by
    WHERE r.status = 'PENDING'
    ORDER BY r.created_at ASC;
END//

-- ============================================================
-- 4. Level 2: Approve a request
-- ============================================================
DROP PROCEDURE IF EXISTS sp_fulfillment_request_approve//

CREATE PROCEDURE sp_fulfillment_request_approve(
    IN p_request_id BIGINT,
    IN p_admin_id   BIGINT,
    IN p_level2_note TEXT
)
BEGIN
    DECLARE v_status VARCHAR(20);

    SELECT status INTO v_status
    FROM gold_fulfillment_requests
    WHERE id = p_request_id;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Request not found';
    ELSEIF v_status != 'PENDING' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Request is not in PENDING status';
    ELSE
        UPDATE gold_fulfillment_requests
        SET status      = 'APPROVED',
            assigned_to = p_admin_id,
            level2_note = p_level2_note
        WHERE id = p_request_id;

        SELECT id, sabbpe_order_id, status
        FROM gold_fulfillment_requests
        WHERE id = p_request_id;
    END IF;
END//

-- ============================================================
-- 5. Level 2: Reject a request
-- ============================================================
DROP PROCEDURE IF EXISTS sp_fulfillment_request_reject//

CREATE PROCEDURE sp_fulfillment_request_reject(
    IN p_request_id BIGINT,
    IN p_admin_id   BIGINT,
    IN p_level2_note TEXT
)
BEGIN
    DECLARE v_status VARCHAR(20);

    SELECT status INTO v_status
    FROM gold_fulfillment_requests
    WHERE id = p_request_id;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Request not found';
    ELSEIF v_status != 'PENDING' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Request is not in PENDING status';
    ELSE
        UPDATE gold_fulfillment_requests
        SET status      = 'REJECTED',
            assigned_to = p_admin_id,
            level2_note = p_level2_note
        WHERE id = p_request_id;

        SELECT id, sabbpe_order_id, status
        FROM gold_fulfillment_requests
        WHERE id = p_request_id;
    END IF;
END//

-- ============================================================
-- 6. Level 2: Mark as processed (gold actually sent)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_fulfillment_request_process//

CREATE PROCEDURE sp_fulfillment_request_process(
    IN p_request_id BIGINT,
    IN p_admin_id   BIGINT,
    IN p_level2_note TEXT
)
BEGIN
    DECLARE v_status VARCHAR(20);

    SELECT status INTO v_status
    FROM gold_fulfillment_requests
    WHERE id = p_request_id;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Request not found';
    ELSEIF v_status != 'APPROVED' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Request must be APPROVED before marking as processed';
    ELSE
        UPDATE gold_fulfillment_requests
        SET status      = 'PROCESSED',
            assigned_to = p_admin_id,
            level2_note = p_level2_note
        WHERE id = p_request_id;

        SELECT id, sabbpe_order_id, status
        FROM gold_fulfillment_requests
        WHERE id = p_request_id;
    END IF;
END//

DELIMITER ;
