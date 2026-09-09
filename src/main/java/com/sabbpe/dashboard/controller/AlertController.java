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

    public record ResolveRequest(String note) {}
    public record AdminActionRequest(Long adminId, String note) {}

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
    public Map<String, Object> refresh(@RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("alerts", alertService.manualRefresh());
        return response;
    }

    /**
     * POST /api/v1/admin/alerts/{id}/acknowledge
     */
    @PostMapping("/{id}/acknowledge")
    public Map<String, Object> acknowledge(@PathVariable long id,
                                           @RequestBody(required = false) Map<String, Object> body) {
        alertService.acknowledge(id, 1L);
        return Map.of("success", true, "message", "Alert acknowledged");
    }

    /**
     * POST /api/v1/admin/alerts/{id}/resolve
     */
    @PostMapping("/{id}/resolve")
    public Map<String, Object> resolve(@PathVariable long id,
                                       @RequestBody(required = false) Map<String, Object> body) {
        String note = body != null && body.get("note") != null ? String.valueOf(body.get("note")) : null;
        alertService.resolve(id, 1L, note);
        return Map.of("success", true, "message", "Alert resolved");
    }
}