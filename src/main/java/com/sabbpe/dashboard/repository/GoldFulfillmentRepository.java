package com.sabbpe.dashboard.repository;

import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Map;

@Repository
public class GoldFulfillmentRepository {

    private final JdbcTemplate jdbc;

    public GoldFulfillmentRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public long createRequest(String uniqueId, long createdBy, String note) {
        Map<String, Object> result = jdbc.queryForMap(
                "CALL sp_fulfillment_request_create(?, ?, ?)",
                uniqueId, createdBy, note);
        return ((Number) result.get("request_id")).longValue();
    }

    public List<Map<String, Object>> lookupByUniqueId(String uniqueId) {
        return jdbc.queryForList("CALL sp_fulfillment_lookup_unique(?)", uniqueId);
    }

    public List<Map<String, Object>> listMine(long adminId) {
        return jdbc.queryForList("CALL sp_fulfillment_request_list_mine(?)", adminId);
    }

    public List<Map<String, Object>> listPending() {
        return jdbc.queryForList("CALL sp_fulfillment_request_list_pending(0)");
    }

    public Map<String, Object> approve(long requestId, long adminId, String note) {
        try {
            return jdbc.queryForMap("CALL sp_fulfillment_request_approve(?, ?, ?)", requestId, adminId, note);
        } catch (EmptyResultDataAccessException ex) {
            return Map.of();
        }
    }

    public Map<String, Object> reject(long requestId, long adminId, String note) {
        try {
            return jdbc.queryForMap("CALL sp_fulfillment_request_reject(?, ?, ?)", requestId, adminId, note);
        } catch (EmptyResultDataAccessException ex) {
            return Map.of();
        }
    }

    public Map<String, Object> process(long requestId, long adminId, String note) {
        try {
            return jdbc.queryForMap("CALL sp_fulfillment_request_process(?, ?, ?)", requestId, adminId, note);
        } catch (EmptyResultDataAccessException ex) {
            return Map.of();
        }
    }

    public Map<String, Object> getRequestById(long requestId) {
        try {
            return jdbc.queryForMap(
                    "SELECT id, sabbpe_order_id, customer_id, customer_name, customer_mobile, " +
                    "order_amount, lock_price, block_id, metal_type, merchant_order_id, " +
                    "status, level1_note, level2_note, retry_count " +
                    "FROM gold_fulfillment_requests WHERE id = ?",
                    requestId);
        } catch (EmptyResultDataAccessException ex) {
            return Map.of();
        }
    }

    public Map<String, Object> updateStatus(long requestId, long adminId, String status, String note) {
        jdbc.update(
                "UPDATE gold_fulfillment_requests SET status = ?, assigned_to = ?, level2_note = ? WHERE id = ?",
                status, adminId, note, requestId);
        return getRequestById(requestId);
    }

    public void incrementRetryCount(long requestId) {
        jdbc.update(
                "UPDATE gold_fulfillment_requests SET retry_count = retry_count + 1, last_retry_at = NOW() WHERE id = ?",
                requestId);
    }

    public void markCashfreeOrderFulfilled(String sabbpeOrderId) {
        jdbc.update(
                "UPDATE cashfreepg_orders SET remarks = 'FULFILLMENT_COMPLETED' WHERE sabbpe_order_id = ?",
                sabbpeOrderId);
    }

    public void markCashfreeOrderFulfilledByMerchant(String merchantTransactionId) {
        jdbc.update(
                "UPDATE cashfreepg_orders SET remarks = 'FULFILLMENT_COMPLETED' WHERE merchant_order_id = ?",
                merchantTransactionId);
    }

    public void saveAugmontResult(String merchantTransactionId, String responseJson,
                                  boolean successful, String providerReference, String failureReason) {
        if (successful) {
            jdbc.update("""
                    UPDATE orders
                    SET order_status = 'completed',
                        provider_reference = ?,
                        provider_response_payload = ?,
                        failure_reason = NULL
                    WHERE merchant_transaction_id = ?
                    """, providerReference, responseJson, merchantTransactionId);
        } else {
            jdbc.update("""
                    UPDATE orders
                    SET order_status = 'failed',
                        provider_response_payload = ?,
                        failure_reason = ?
                    WHERE merchant_transaction_id = ?
                      AND COALESCE(order_status, '') <> 'completed'
                    """, responseJson, failureReason, merchantTransactionId);
        }
    }

    public void markCashfreeOrderFailedByMerchant(String merchantTransactionId, String failureReason) {
        jdbc.update("""
                UPDATE cashfreepg_orders
                SET remarks = LEFT(CONCAT('FULFILLMENT_FAILED: ', ?), 255)
                WHERE merchant_order_id = ?
                  AND COALESCE(remarks, '') NOT LIKE 'FULFILLMENT_COMPLETED%'
                """, failureReason, merchantTransactionId);
    }
}
