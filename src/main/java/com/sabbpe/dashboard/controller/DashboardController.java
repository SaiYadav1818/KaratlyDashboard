package com.sabbpe.dashboard.controller;

import com.sabbpe.dashboard.repository.DashboardRepository;
import org.springframework.web.bind.annotation.*;

import java.util.LinkedHashMap;
import java.util.Map;

@RestController
@RequestMapping("/api/v1/admin/dashboard")
public class DashboardController {

    private final DashboardRepository repository;

    public DashboardController(DashboardRepository repository) {
        this.repository = repository;
    }

    /**
     * GET /api/v1/admin/dashboard/overview?days=30
     * Returns KPIs + day-wise trend arrays.
     */
    @GetMapping("/overview")
    public Map<String, Object> overview(@RequestParam(defaultValue = "30") int days) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("kpis", repository.kpis(days));
        response.put("daily", repository.daily(days));
        return response;
    }

    /**
     * GET /api/v1/admin/dashboard/users?from=&to=&search=&kyc=
     * Returns every user as one row.
     */
    @GetMapping("/users")
    public Map<String, Object> users(
            @RequestParam(required = false) String from,
            @RequestParam(required = false) String to,
            @RequestParam(required = false) String search,
            @RequestParam(required = false) String kyc
    ) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("users", repository.users(blankToNull(from), blankToNull(to),
                blankToNull(search), blankToNull(kyc)));
        return response;
    }

    /**
     * GET /api/v1/admin/dashboard/users/{clientId}
     * Returns a single user's profile, orders, banks and addresses.
     */
    @GetMapping("/users/{clientId}")
    public Map<String, Object> userDetail(@PathVariable String clientId) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("profile", repository.userProfile(clientId));
        response.put("orders", repository.userOrders(clientId));
        response.put("banks", repository.userBanks(clientId));
        response.put("addresses", repository.userAddresses(clientId));
        return response;
    }

    /**
     * GET /api/v1/admin/dashboard/orders-summary?days=30
     * One row: buy/sell/redeem counts, success/failed/pending, paid, augmont purchased.
     */
    @GetMapping("/orders-summary")
    public Map<String, Object> ordersSummary(@RequestParam(defaultValue = "30") int days) {
        return repository.ordersSummary(days);
    }

    /**
     * GET /api/v1/admin/dashboard/recent-transactions?days=7&limit=50&status=ALL
     * status: ALL | SUCCESS | FAILED | PENDING
     */
    @GetMapping("/recent-transactions")
    public Map<String, Object> recentTransactions(
            @RequestParam(defaultValue = "7") int days,
            @RequestParam(defaultValue = "50") int limit,
            @RequestParam(defaultValue = "ALL") String status
    ) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("transactions", repository.recentTransactions(days, limit, status));
        return response;
    }

    private String blankToNull(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        return value.trim();
    }
}
