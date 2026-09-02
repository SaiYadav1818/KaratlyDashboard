-- ============================================================
-- Karatly Admin Dashboard - Admin Authentication
-- Database: sabbpekaratly (MariaDB)
--
-- Table: dashboard_admin_users  (the ONLY new table — for admin login)
-- Procs: sp_dashboard_admin_*
--
-- Password hashing is BCrypt (done in Java — MariaDB has no BCrypt).
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
-- Seed super admin (default password: admin@123 — CHANGE IT)
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
