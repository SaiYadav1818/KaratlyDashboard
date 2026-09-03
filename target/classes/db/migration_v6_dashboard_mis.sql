-- ============================================================
-- Karatly Admin Dashboard - MIS Overview (v2: + diamond, + watchlist)
-- Database: sabbpekaratly (MariaDB)
--
-- Procs:
--   sp_dashboard_mis_overview()    -> GMV + txn + users + metals (gold/silver/diamond) + coupons
--   sp_dashboard_mis_aum()         -> Metal Balance (AUM) metrics
--   sp_dashboard_mis_coupons()     -> Coupon usage metrics
--   sp_dashboard_mis_watchlist()   -> Metal watchlist (margin + volume outliers)
--
-- NOT AVAILABLE from sabbpekaratly (frontend should hide these sections):
--   Karatly Earn (commission)  - no commission concept stored anywhere
--   Karatly Payout (wallet)    - payout not implemented
--   Customer Earn (wallet pts) - lives in sabbpegiftvouchers DB
--   Customer Burn (cashback)   - lives in sabbpegiftvouchers DB
--   Profit                     - requires commission data (not available)
-- ============================================================

DELIMITER //

-- ============================================================
-- 1. MIS OVERVIEW: GMV + Transaction Count + Users + Metals + Coupons
-- ============================================================
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

    -- GMV YTD
    SELECT
        -- Business Value (GMV)
        COALESCE(ytd.ytd_count, 0) AS gmv_ytd_count,
        COALESCE(ytd.ytd_value, 0) AS gmv_ytd_value,
        COALESCE(mtd.mtd_count, 0) AS gmv_mtd_count,
        COALESCE(mtd.mtd_value, 0) AS gmv_mtd_value,
        COALESCE(ftd.ftd_count, 0) AS gmv_ftd_count,
        COALESCE(ftd.ftd_value, 0) AS gmv_ftd_value,

        -- Transaction Count (MTD)
        COALESCE(txn.txn_total, 0) AS txn_mtd_total,
        COALESCE(txn.txn_success, 0) AS txn_mtd_success,
        COALESCE(txn.txn_failed, 0) AS txn_mtd_failed,

        -- Users
        COALESCE(usr.unique_users, 0) AS unique_users,
        COALESCE(usr.repeat_users, 0) AS repeat_users,
        COALESCE(usr.flagged_users, 0) AS flagged_users,

        -- Metal Holdings
        COALESCE(met.gold_grams, 0) AS gold_grams,
        COALESCE(met.gold_value, 0) AS gold_value,
        COALESCE(met.silver_grams, 0) AS silver_grams,
        COALESCE(met.silver_value, 0) AS silver_value,
        COALESCE(diam.diamond_carats, 0) AS diamond_carats,
        COALESCE(diam.diamond_value, 0) AS diamond_value,
        COALESCE(diam.diamond_count, 0) AS diamond_count,
        CASE WHEN COALESCE(ytd.ytd_value, 0) > 0
             THEN ROUND(COALESCE(met.gold_value, 0) / ytd.ytd_value * 100, 1)
             ELSE 0 END AS gold_pct_gmv,
        CASE WHEN COALESCE(ytd.ytd_value, 0) > 0
             THEN ROUND(COALESCE(met.silver_value, 0) / ytd.ytd_value * 100, 1)
             ELSE 0 END AS silver_pct_gmv,
        CASE WHEN COALESCE(ytd.ytd_value, 0) > 0
             THEN ROUND(COALESCE(diam.diamond_value, 0) / ytd.ytd_value * 100, 1)
             ELSE 0 END AS diamond_pct_gmv,

        -- Coupon usage
        COALESCE(cpn.coupon_count, 0) AS coupons_redeemed_count,
        COALESCE(cpn.coupon_value, 0) AS coupons_redeemed_value

    FROM (SELECT 1) dummy
    -- GMV YTD
    LEFT JOIN (
        SELECT
            COUNT(*) AS ytd_count,
            SUM(COALESCE(o.total_amount, 0)) AS ytd_value
        FROM orders o
        WHERE o.order_type IN ('digital_purchase','digital_sell','physical_redemption','diamond_purchase')
          AND o.created_at >= v_ytd_start
    ) ytd ON 1=1
    -- GMV MTD
    LEFT JOIN (
        SELECT
            COUNT(*) AS mtd_count,
            SUM(COALESCE(o.total_amount, 0)) AS mtd_value
        FROM orders o
        WHERE o.order_type IN ('digital_purchase','digital_sell','physical_redemption','diamond_purchase')
          AND o.created_at >= v_mtd_start
    ) mtd ON 1=1
    -- GMV FTD
    LEFT JOIN (
        SELECT
            COUNT(*) AS ftd_count,
            SUM(COALESCE(o.total_amount, 0)) AS ftd_value
        FROM orders o
        WHERE o.order_type IN ('digital_purchase','digital_sell','physical_redemption','diamond_purchase')
          AND o.created_at >= v_ftd_start
    ) ftd ON 1=1
    -- Transaction count MTD
    LEFT JOIN (
        SELECT
            COUNT(*) AS txn_total,
            SUM(CASE WHEN UPPER(COALESCE(pt.payment_status, cfp.payment_status, '')) = 'SUCCESS' THEN 1 ELSE 0 END) AS txn_success,
            SUM(CASE WHEN UPPER(COALESCE(pt.payment_status, cfp.payment_status, '')) = 'FAILED' THEN 1 ELSE 0 END) AS txn_failed
        FROM orders o
        LEFT JOIN payment_transactions pt ON o.order_id = pt.order_id
        LEFT JOIN cashfreepg_orders cfo ON cfo.merchant_order_id = o.merchant_transaction_id
        LEFT JOIN cashfreepg_payments cfp ON cfp.sabbpe_order_id = cfo.sabbpe_order_id
        WHERE o.order_type IN ('digital_purchase','digital_sell','physical_redemption','diamond_purchase')
          AND o.created_at >= v_mtd_start
    ) txn ON 1=1
    -- Users segmentation
    LEFT JOIN (
        SELECT
            COUNT(DISTINCT cp.client_id) AS unique_users,
            SUM(CASE WHEN o.client_order_count > 1 THEN 1 ELSE 0 END) AS repeat_users,
            (SELECT COUNT(*) FROM client_profile WHERE kyc_status = 'rejected' OR kyc_status = 'failed') AS flagged_users
        FROM client_profile cp
        LEFT JOIN (
            SELECT client_id, COUNT(*) AS client_order_count
            FROM orders
            WHERE order_type IN ('digital_purchase','digital_sell','physical_redemption','diamond_purchase')
            GROUP BY client_id
        ) o ON cp.client_id = o.client_id
    ) usr ON 1=1
    -- Metal holdings (NET = bought - sold, live balances from customer_asset_holdings)
    LEFT JOIN (
        SELECT
            SUM(CASE WHEN asset_type = 'gold'   THEN total_quantity ELSE 0 END) AS gold_grams,
            SUM(CASE WHEN asset_type = 'gold'   THEN COALESCE(valuation_inr, 0) ELSE 0 END) AS gold_value,
            SUM(CASE WHEN asset_type = 'silver' THEN total_quantity ELSE 0 END) AS silver_grams,
            SUM(CASE WHEN asset_type = 'silver' THEN COALESCE(valuation_inr, 0) ELSE 0 END) AS silver_value
        FROM customer_asset_holdings
    ) met ON 1=1
    -- Diamond holdings
    LEFT JOIN (
        SELECT
            COUNT(*) AS diamond_count,
            COALESCE(SUM(o.total_amount), 0) AS diamond_value,
            COALESCE(SUM(di.weight), 0) AS diamond_carats
        FROM orders o
        LEFT JOIN JSON_TABLE(o.pricing_snapshot, '$.items[*]'
            COLUMNS (productId VARCHAR(36) PATH '$.productId')) jt ON TRUE
        LEFT JOIN diamond_inventory di ON di.id = jt.productId
        WHERE o.order_type = 'diamond_purchase'
          AND o.order_status IN ('completed', 'confirmed')
          AND o.created_at >= v_ytd_start
    ) diam ON 1=1
    -- Coupon usage YTD
    LEFT JOIN (
        SELECT
            COUNT(*) AS coupon_count,
            SUM(cu.discount_amount) AS coupon_value
        FROM coupon_usage cu
        WHERE cu.used_at >= v_ytd_start
    ) cpn ON 1=1;
END//

-- ============================================================
-- 2. AUM: Metal Balance (Assets Under Management)
-- ============================================================
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
        CASE WHEN DAY(v_today) > 0
             THEN ROUND(COALESCE(SUM(CASE WHEN o.created_at >= v_mtd_start THEN COALESCE(o.total_amount, 0) ELSE 0 END), 0) / DAY(v_today) * 30, 0)
             ELSE 0 END AS aum_run_rate_monthly,
        CASE WHEN v_total_users > 0
             THEN ROUND(COALESCE(SUM(COALESCE(o.total_amount, 0)), 0) / v_total_users, 0)
             ELSE 0 END AS avg_holding_per_user,
        CASE WHEN COALESCE(SUM(CASE WHEN o.order_type = 'digital_purchase' THEN COALESCE(o.total_amount, 0) ELSE 0 END), 0) > 0
             THEN ROUND(
                 COALESCE(SUM(CASE WHEN o.order_type = 'digital_sell' THEN COALESCE(o.total_amount, 0) ELSE 0 END), 0) /
                 COALESCE(SUM(CASE WHEN o.order_type = 'digital_purchase' THEN COALESCE(o.total_amount, 0) ELSE 0 END), 1) * 100,
             1)
             ELSE 0 END AS redemption_rate_pct
    FROM orders o
    WHERE o.order_type IN ('digital_purchase', 'digital_sell')
      AND o.order_status IN ('completed', 'confirmed');
END//

-- ============================================================
-- 3. COUPONS: Usage metrics
-- ============================================================
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

-- ============================================================
-- 4. METAL WATCHLIST: margin (spread) + volume outliers
--    spread = latest AUGMONT buy rate - sell rate, as % of buy rate
--    volume = grams purchased in last 30 days
-- ============================================================
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
        SELECT metal_type,
               buy_rate,
               sell_rate,
               ROUND((buy_rate - sell_rate) / buy_rate * 100, 1) AS spread_pct
        FROM rate_rows
        WHERE sell_rate IS NOT NULL AND buy_rate > 0
    ),
    volumes AS (
        SELECT metal, SUM(grams) AS grams FROM (
            SELECT
                COALESCE(
                    JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.metalType')),
                    JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.assetType')),
                    'gold'
                ) AS metal,
                CAST(COALESCE(
                    NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.provider_response_payload, '$.result.data.quantity')), ''),
                    NULLIF(JSON_UNQUOTE(JSON_EXTRACT(o.pricing_snapshot, '$.quantity')), ''),
                    '0'
                ) AS DECIMAL(18,4)) AS grams
            FROM orders o
            WHERE o.order_type = 'digital_purchase' AND o.order_status IN ('completed','confirmed')
              AND o.created_at >= v_since
            UNION ALL
            SELECT 'diamond', di.weight
            FROM orders o
            LEFT JOIN JSON_TABLE(o.pricing_snapshot, '$.items[*]'
                COLUMNS (productId VARCHAR(36) PATH '$.productId')) jt ON TRUE
            LEFT JOIN diamond_inventory di ON di.id = jt.productId
            WHERE o.order_type = 'diamond_purchase' AND o.order_status IN ('completed','confirmed')
              AND o.created_at >= v_since
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
             SELECT 'gold' AS metal
             UNION SELECT 'silver'
             UNION SELECT 'platinum'
             UNION SELECT 'pearl'
             UNION SELECT 'diamond'
         ) allmetals
         WHERE metal NOT IN (SELECT metal FROM volumes WHERE grams > 0)) AS zero_volume_metals;
END//

DELIMITER ;