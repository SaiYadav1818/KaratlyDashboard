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

    public Map<String, Object> createRequest(String adminId, String uniqueId, String note) {
        long adminIdLong = safeAdminId(adminId);
        if (uniqueId == null || uniqueId.isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "uniqueId is required");
        }

        long requestId = repository.createRequest(uniqueId.trim(), adminIdLong, note);

        // Return the created request with all resolved details (merchant id, augmont message, etc.)
        Map<String, Object> created = repository.getRequestById(requestId);

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("success", true);
        result.put("request_id", requestId);
        result.put("request", created);
        result.put("message", "Request sent to Level 2 admin");
        return result;
    }

    private long safeAdminId(String adminId) {
        if (adminId == null || adminId.isBlank() || "null".equalsIgnoreCase(adminId)) {
            return 1L;
        }
        try {
            return Long.parseLong(adminId.trim());
        } catch (NumberFormatException e) {
            return 1L;
        }
    }

    public Map<String, Object> lookupByUniqueId(String adminId, String uniqueId) {
        if (uniqueId == null || uniqueId.isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "uniqueId is required");
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("orders", repository.lookupByUniqueId(uniqueId.trim()));
        return result;
    }

    public Map<String, Object> listPending(String adminId) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("requests", repository.listPending());
        return result;
    }

    /**
     * Proxy retry-buy: forwards the exact request body that
     * https://uatbckend.karatly.net/api/v1/orders/buy/create expects.
     * The dashboard does NOT build the buy request — caller sends it.
     * Only call to sabbpe backend + return its response.
     */
    public Map<String, Object> retryBuy(Map<String, Object> body) {
        Map<String, Object> buyResponse = sabbpeBackendService.createBuyOrder(body);
        return buyResponse;
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
        // payload.result.data.rates.{gBuy|sBuy} and payload.result.data.blockId
        String lockPrice = "";
        String blockId = "";
        try {
            Object payloadObj = liveRates.get("payload");
            if (payloadObj instanceof Map<?, ?> payloadMap) {
                Object resultObj = payloadMap.get("result");
                if (resultObj instanceof Map<?, ?> resultMap) {
                    Object dataObj = resultMap.get("data");
                    if (dataObj instanceof Map<?, ?> dataMap) {
                        blockId = String.valueOf(dataMap.get("blockId"));
                        Object ratesObj = dataMap.get("rates");
                        if (ratesObj instanceof Map<?, ?> ratesMap) {
                            if ("silver".equalsIgnoreCase(metalType)) {
                                lockPrice = String.valueOf(ratesMap.get("sBuy"));
                            } else {
                                lockPrice = String.valueOf(ratesMap.get("gBuy"));
                            }
                        }
                    }
                }
            }
        } catch (Exception e) {
            log.warn("Failed to extract live rate, using empty values", e);
        }

        // 4. Increment retry count
        repository.incrementRetryCount(requestId);

        // 5. Call Sabbpegold's buy endpoint with live rate (wrapper format)
        // Send exactly what buy/create wants: merchantId + request wrapper.
        Map<String, Object> innerRequest = new LinkedHashMap<>();
        innerRequest.put("lockPrice", lockPrice);
        innerRequest.put("metalType", metalType);
        innerRequest.put("quantity", null);
        innerRequest.put("amount", String.valueOf(orderAmount));
        innerRequest.put("merchantTransactionId", merchantOrderId);
        innerRequest.put("uniqueId", customerId);
        innerRequest.put("phoneNumber", customerMobile);
        innerRequest.put("blockId", blockId);
        innerRequest.put("modeOfPayment", "CASHFREE");
        innerRequest.put("mobileNumber", customerMobile);

        Map<String, Object> buyRequest = new LinkedHashMap<>();
        buyRequest.put("merchantId", merchantOrderId);
        buyRequest.put("request", innerRequest);

        log.info("Retry buy request: {}", buyRequest);
        Map<String, Object> buyResponse = sabbpeBackendService.createBuyOrder(buyRequest);
        log.info("Retry buy response: {}", buyResponse);

        // 6. Check if buy was successful
        String buyStatus = String.valueOf(buyResponse.getOrDefault("status", ""));
        boolean success = "success".equalsIgnoreCase(buyStatus)
                || "SUCCESS".equalsIgnoreCase(buyStatus);

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
}
