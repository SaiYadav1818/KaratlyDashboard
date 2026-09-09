package com.sabbpe.dashboard.controller;

import com.sabbpe.dashboard.service.GoldFulfillmentService;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

@RestController
@RequestMapping("/api/v1/admin/fulfillment")
public class GoldFulfillmentController {

    private final GoldFulfillmentService service;

    public GoldFulfillmentController(GoldFulfillmentService service) {
        this.service = service;
    }

    public record CreateRequest(long adminId, String sabbpeOrderId, String customerId,
                                String customerName, String customerMobile, double orderAmount,
                                String metalType, String merchantOrderId, String level1Note) {}

    public record PendingRequest(long adminId) {}

    public record RetryRequest(long adminId, String note) {}

    /**
     * POST /api/v1/admin/fulfillment/create
     * Level 1 admin: send a request to Level 2
     */
    @PostMapping("/create")
    public Map<String, Object> createRequest(@RequestBody CreateRequest request) {
        return service.createRequest(String.valueOf(request.adminId()), Map.of(
                "sabbpe_order_id", request.sabbpeOrderId(),
                "customer_id", request.customerId(),
                "customer_name", request.customerName() != null ? request.customerName() : "",
                "customer_mobile", request.customerMobile() != null ? request.customerMobile() : "",
                "order_amount", request.orderAmount(),
                "metal_type", request.metalType() != null ? request.metalType() : "gold",
                "merchant_order_id", request.merchantOrderId() != null ? request.merchantOrderId() : "",
                "level1_note", request.level1Note() != null ? request.level1Note() : ""
        ));
    }

    /**
     * POST /api/v1/admin/fulfillment/pending
     * Level 2 admin: list all pending requests
     */
    @PostMapping("/pending")
    public Map<String, Object> listPending(@RequestBody PendingRequest request) {
        return service.listPending(String.valueOf(request.adminId()));
    }

    /**
     * POST /api/v1/admin/fulfillment/{id}/retry-buy
     * Level 2 admin: retry gold buy for a failed order using live rate
     */
    @PostMapping("/{id}/retry-buy")
    public Map<String, Object> retryBuy(@PathVariable("id") long requestId,
                                        @RequestBody RetryRequest request) {
        return service.retryBuy(String.valueOf(request.adminId()), requestId, request.note());
    }
}
