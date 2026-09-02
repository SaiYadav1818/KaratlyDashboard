package com.sabbpe.dashboard.repository;

import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Map;

@Repository
public class AlertRepository {

    private final JdbcTemplate jdbc;

    public AlertRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public List<Map<String, Object>> refresh() {
        return jdbc.queryForList("CALL sp_dashboard_alerts_refresh()");
    }

    public List<Map<String, Object>> list(int days, String category, String severity, String status) {
        return jdbc.queryForList("CALL sp_dashboard_alerts_list(?, ?, ?, ?)", days, category, severity, status);
    }

    public Map<String, Object> summary() {
        List<Map<String, Object>> rows = jdbc.queryForList("CALL sp_dashboard_alerts_summary()");
        return rows.isEmpty() ? Map.of() : rows.get(0);
    }

    public void acknowledge(long id, long adminId) {
        jdbc.update("CALL sp_dashboard_alerts_acknowledge(?, ?)", id, adminId);
    }

    public void resolve(long id, long adminId, String note) {
        jdbc.update("CALL sp_dashboard_alerts_resolve(?, ?, ?)", id, adminId, note);
    }
}
