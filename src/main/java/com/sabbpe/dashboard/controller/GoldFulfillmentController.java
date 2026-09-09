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

    public record CreateRequest(Long adminId, String uniqueId, String level1Note) {}

    public record PendingRequest(Long adminId) {}

    public record LookupRequest(Long adminId, String uniqueId) {}

    public record RetryRequest(Long adminId, String note) {}

    /**
     * POST /api/v1/admin/fulfillment/create
     * Level 1 admin: send request to Level 2 using ONLY the unique id.
     * All order details (merchant id, amount, augmont message) are auto-fetched.
     */
    @PostMapping("/create")
    public Map<String, Object> createRequest(@RequestBody CreateRequest request) {
        return service.createRequest(String.valueOf(request.adminId()),
                request.uniqueId(), request.level1Note() != null ? request.level1Note() : "");
    }

    /**
     * POST /api/v1/admin/fulfillment/lookup-unique
     * Get all order + buy request details (especially merchant id + augmont message)
     * for a unique id. For Level 1 before sending, and Level 2 to review.
     */
    @PostMapping("/lookup-unique")
    public Map<String, Object> lookupByUniqueId(@RequestBody LookupRequest request) {
        return service.lookupByUniqueId(String.valueOf(request.adminId()), request.uniqueId());
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
