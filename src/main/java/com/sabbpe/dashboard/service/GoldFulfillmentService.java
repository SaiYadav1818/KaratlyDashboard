package com.sabbpe.dashboard.service;

import com.sabbpe.dashboard.repository.GoldFulfillmentRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

import java.util.LinkedHashMap;
import java.util.Map;

@Service
public class GoldFulfillmentService {

    private static final Logger log = LoggerFactory.getLogger(GoldFulfillmentService.class);

    private final GoldFulfillmentRepository repository;
    private final SabbpeBackendService sabbpeBackendService;

    public GoldFulfillmentService(GoldFulfillmentRepository repository,
                                   SabbpeBackendService sabbpeBackendService) {
        this.repository = repository;
        this.sabbpeBackendService = sabbpeBackendService;
    }

    public Map<String, Object> createRequest(String adminId, Map<String, Object> request) {
        long adminIdLong = Long.parseLong(adminId);
        String sabbpeOrderId = getStringOrThrow(request, "sabbpe_order_id");
        String customerId = getStringOrThrow(request, "customer_id");
        String customerName = getOrDefault(request, "customer_name", "");
        String customerMobile = getOrDefault(request, "customer_mobile", "");
        double orderAmount = getDoubleOrThrow(request, "order_amount");
        String metalType = getOrDefault(request, "metal_type", "gold");
        String merchantOrderId = getOrDefault(request, "merchant_order_id", null);
        String note = getOrDefault(request, "level1_note", null);

        long requestId = repository.createRequest(sabbpeOrderId, customerId, customerName,
                customerMobile, orderAmount, null, null, metalType, merchantOrderId,
                adminIdLong, note);

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("success", true);
        result.put("request_id", requestId);
        result.put("message", "Request sent to Level 2 admin");
        return result;
    }

    public Map<String, Object> listPending(String adminId) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("requests", repository.listPending());
        return result;
    }

    /**
     * Level 2 admin retries gold buy for a failed order.
     * Fetches live rate from Sabbpegold and uses it for the buy.
     */
    @SuppressWarnings("unchecked")
    public Map<String, Object> retryBuy(String adminId, long requestId, String note) {
        // 1. Load the request
        Map<String, Object> request = repository.getRequestById(requestId);
        if (request.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Request not found");
        }
        String status = String.valueOf(request.get("status"));
        if ("PROCESSED".equals(status)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Request already processed");
        }

        String sabbpeOrderId = String.valueOf(request.get("sabbpe_order_id"));
        String metalType = String.valueOf(request.getOrDefault("metal_type", "gold"));
        String merchantOrderId = String.valueOf(request.get("merchant_order_id"));
        String customerId = String.valueOf(request.get("customer_id"));
        String customerMobile = String.valueOf(request.get("customer_mobile"));
        double orderAmount = ((Number) request.get("order_amount")).doubleValue();

        // 2. Fetch live rate from Sabbpegold
        Map<String, Object> liveRates = sabbpeBackendService.fetchLiveRates();
        log.info("Live rates response: {}", liveRates);

        // 3. Extract lockPrice and blockId from live rates
        String lockPrice = "";
        String blockId = "";
        try {
            Object payload = liveRates.get("payload");
            if (payload instanceof Map<?, ?> payloadMap) {
                // Try to get gold buy rate
                Object goldBuy = payloadMap.get("goldBuy");
                if (goldBuy instanceof Map<?, ?> goldBuyMap) {
                    lockPrice = String.valueOf(goldBuyMap.get("lockPrice"));
                    blockId = String.valueOf(goldBuyMap.get("blockId"));
                }
                // If silver, try silverBuy
                if ("silver".equalsIgnoreCase(metalType)) {
                    Object silverBuy = payloadMap.get("silverBuy");
                    if (silverBuy instanceof Map<?, ?> silverBuyMap) {
                        lockPrice = String.valueOf(silverBuyMap.get("lockPrice"));
                        blockId = String.valueOf(silverBuyMap.get("blockId"));
                    }
                }
            }
        } catch (Exception e) {
            log.warn("Failed to extract live rate, using empty values", e);
        }

        // 4. Increment retry count
        repository.incrementRetryCount(requestId);

        // 5. Call Sabbpegold's buy endpoint with live rate
        Map<String, Object> buyRequest = new LinkedHashMap<>();
        buyRequest.put("lockPrice", lockPrice);
        buyRequest.put("metalType", metalType);
        buyRequest.put("quantity", null);
        buyRequest.put("amount", String.valueOf(orderAmount));
        buyRequest.put("merchantTransactionId", merchantOrderId);
        buyRequest.put("uniqueId", customerId);
        buyRequest.put("phoneNumber", customerMobile);
        buyRequest.put("blockId", blockId);
        buyRequest.put("modeOfPayment", "CASHFREE");
        buyRequest.put("userName", null);
        buyRequest.put("mobileNumber", customerMobile);

        log.info("Retry buy request: {}", buyRequest);
        Map<String, Object> buyResponse = sabbpeBackendService.createBuyOrder(buyRequest);
        log.info("Retry buy response: {}", buyResponse);

        // 6. Check if buy was successful
        String buyStatus = String.valueOf(buyResponse.getOrDefault("status", ""));
        boolean success = "SUCCESS".equals(buyStatus);

        // 7. If buy succeeded, mark the cashfree order as fulfilled so it stops showing as unfulfilled
        if (success) {
            repository.markCashfreeOrderFulfilled(sabbpeOrderId);
        }

        // 8. Update fulfillment request status
        long adminIdLong = Long.parseLong(adminId);
        String updatedStatus = success ? "PROCESSED" : "REJECTED";
        String updatedNote = success
                ? (note == null || note.isEmpty() ? "Gold purchased via retry at live rate" : note)
                : (note == null || note.isEmpty() ? "Retry failed: " + buyResponse.getOrDefault("message", "unknown") : note);

        Map<String, Object> updated = repository.updateStatus(requestId, adminIdLong, updatedStatus, updatedNote);

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("success", success);
        result.put("request", updated);
        result.put("sabbpe_order_id", sabbpeOrderId);
        result.put("live_rate_used", lockPrice);
        result.put("buy_response", buyResponse);
        return result;
    }

    private String getStringOrThrow(Map<String, Object> map, String key) {
        Object val = map.get(key);
        if (val == null || val.toString().isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, key + " is required");
        }
        return val.toString().trim();
    }

    private String getOrDefault(Map<String, Object> map, String key, String defaultVal) {
        Object val = map.get(key);
        if (val == null || val.toString().isBlank()) {
            return defaultVal;
        }
        return val.toString().trim();
    }

    private double getDoubleOrThrow(Map<String, Object> map, String key) {
        Object val = map.get(key);
        if (val == null) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, key + " is required");
        }
        if (val instanceof Number n) {
            return n.doubleValue();
        }
        try {
            return Double.parseDouble(val.toString());
        } catch (NumberFormatException e) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, key + " must be a number");
        }
    }
}
