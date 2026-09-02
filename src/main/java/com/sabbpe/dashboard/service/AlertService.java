package com.sabbpe.dashboard.service;

import com.sabbpe.dashboard.repository.AlertRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.Map;

@Service
public class AlertService {

    private static final Logger log = LoggerFactory.getLogger(AlertService.class);

    private final AlertRepository repository;

    public AlertService(AlertRepository repository) {
        this.repository = repository;
    }

    /**
     * Auto-scan every 5 minutes. Runs in background, logs results.
     */
    @Scheduled(fixedRate = 300000, initialDelay = 30000)
    public void scheduledScan() {
        try {
            List<Map<String, Object>> result = repository.refresh();
            long totalOpen = result.stream()
                    .mapToLong(r -> ((Number) r.getOrDefault("cnt", 0)).longValue())
                    .sum();
            log.info("Alert scan completed. Total open alerts: {}", totalOpen);
        } catch (Exception ex) {
            log.error("Alert scan failed: {}", ex.getMessage(), ex);
        }
    }

    /**
     * Manual refresh — same as scheduled scan, returns results immediately.
     */
    public List<Map<String, Object>> manualRefresh() {
        return repository.refresh();
    }

    public List<Map<String, Object>> list(int days, String category, String severity, String status) {
        return repository.list(days, category, severity, status);
    }

    public Map<String, Object> summary() {
        return repository.summary();
    }

    public void acknowledge(long id, long adminId) {
        repository.acknowledge(id, adminId);
    }

    public void resolve(long id, long adminId, String note) {
        repository.resolve(id, adminId, note);
    }
}
