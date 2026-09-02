package com.sabbpe.dashboard.repository;

import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Map;

@Repository
public class DashboardRepository {

    private final JdbcTemplate jdbc;

    public DashboardRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Map<String, Object> kpis(int days) {
        List<Map<String, Object>> rows = jdbc.queryForList("CALL sp_dashboard_kpis(?)", days);
        return rows.isEmpty() ? Map.of() : rows.get(0);
    }

    public List<Map<String, Object>> daily(int days) {
        return jdbc.queryForList("CALL sp_dashboard_daily(?)", days);
    }

    public List<Map<String, Object>> users(String from, String to, String search, String kyc) {
        return jdbc.queryForList("CALL sp_dashboard_users(?, ?, ?, ?)", from, to, search, kyc);
    }

    public Map<String, Object> userProfile(String clientId) {
        try {
            return jdbc.queryForMap("CALL sp_dashboard_user_profile(?)", clientId);
        } catch (EmptyResultDataAccessException ex) {
            return Map.of();
        }
    }

    public List<Map<String, Object>> userOrders(String clientId) {
        return jdbc.queryForList("CALL sp_dashboard_user_orders(?)", clientId);
    }

    public List<Map<String, Object>> userBanks(String clientId) {
        return jdbc.queryForList("CALL sp_dashboard_user_banks(?)", clientId);
    }

    public List<Map<String, Object>> userAddresses(String clientId) {
        return jdbc.queryForList("CALL sp_dashboard_user_addresses(?)", clientId);
    }

    public Map<String, Object> ordersSummary(int days) {
        List<Map<String, Object>> rows = jdbc.queryForList("CALL sp_dashboard_orders_summary(?)", days);
        return rows.isEmpty() ? Map.of() : rows.get(0);
    }

    public List<Map<String, Object>> recentTransactions(int days, int limit, String status) {
        return jdbc.queryForList("CALL sp_dashboard_recent_transactions(?, ?, ?)", days, limit, status);
    }

    public List<Map<String, Object>> orderAudit(String merchantTransactionId) {
        return jdbc.queryForList("CALL sp_dashboard_order_audit(?)", merchantTransactionId);
    }

    public Map<String, Object> misOverview() {
        List<Map<String, Object>> rows = jdbc.queryForList("CALL sp_dashboard_mis_overview()");
        return rows.isEmpty() ? Map.of() : rows.get(0);
    }

    public Map<String, Object> misAum() {
        List<Map<String, Object>> rows = jdbc.queryForList("CALL sp_dashboard_mis_aum()");
        return rows.isEmpty() ? Map.of() : rows.get(0);
    }

    public Map<String, Object> misCoupons() {
        List<Map<String, Object>> rows = jdbc.queryForList("CALL sp_dashboard_mis_coupons()");
        return rows.isEmpty() ? Map.of() : rows.get(0);
    }

    public Map<String, Object> misWatchlist() {
        List<Map<String, Object>> rows = jdbc.queryForList("CALL sp_dashboard_mis_watchlist()");
        return rows.isEmpty() ? Map.of() : rows.get(0);
    }
}
