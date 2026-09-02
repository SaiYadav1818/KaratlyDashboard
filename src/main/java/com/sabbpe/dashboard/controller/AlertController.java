package com.sabbpe.dashboard.controller;

import com.sabbpe.dashboard.service.AlertService;
import org.springframework.web.bind.annotation.*;

import java.util.LinkedHashMap;
import java.util.Map;

@RestController
@RequestMapping("/api/v1/admin/alerts")
public class AlertController {

    private final AlertService alertService;

    public AlertController(AlertService alertService) {
        this.alertService = alertService;
    }

    public record AcknowledgeRequest() {}
    public record ResolveRequest(String note) {}

    /**
     * GET /api/v1/admin/alerts?days=7&category=&severity=&status=open
     */
    @GetMapping
    public Map<String, Object> list(
            @RequestParam(defaultValue = "7") int days,
            @RequestParam(required = false) String category,
            @RequestParam(required = false) String severity,
            @RequestParam(defaultValue = "open") String status
    ) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("alerts", alertService.list(days, category, severity, status));
        return response;
    }

    /**
     * GET /api/v1/admin/alerts/summary
     */
    @GetMapping("/summary")
    public Map<String, Object> summary() {
        return alertService.summary();
    }

    /**
     * POST /api/v1/admin/alerts/refresh — manual scan
     */
    @PostMapping("/refresh")
    public Map<String, Object> refresh(@RequestAttribute("adminId") String adminId) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("alerts", alertService.manualRefresh());
        return response;
    }

    /**
     * POST /api/v1/admin/alerts/{id}/acknowledge
     */
    @PostMapping("/{id}/acknowledge")
    public Map<String, Object> acknowledge(@PathVariable long id,
                                           @RequestAttribute("adminId") String adminId) {
        alertService.acknowledge(id, Long.parseLong(adminId));
        return Map.of("success", true, "message", "Alert acknowledged");
    }

    /**
     * POST /api/v1/admin/alerts/{id}/resolve
     */
    @PostMapping("/{id}/resolve")
    public Map<String, Object> resolve(@PathVariable long id,
                                       @RequestAttribute("adminId") String adminId,
                                       @RequestBody(required = false) ResolveRequest request) {
        String note = request != null ? request.note() : null;
        alertService.resolve(id, Long.parseLong(adminId), note);
        return Map.of("success", true, "message", "Alert resolved");
    }
}
