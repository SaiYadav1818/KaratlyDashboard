package com.sabbpe.dashboard.repository;

import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Map;

@Repository
public class AdminAuthRepository {

    private final JdbcTemplate jdbc;

    public AdminAuthRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Map<String, Object> getByPhone(String phone) {
        try {
            return jdbc.queryForMap("CALL sp_dashboard_admin_get_by_phone(?)", phone);
        } catch (EmptyResultDataAccessException ex) {
            return Map.of();
        }
    }

    public Map<String, Object> getById(long id) {
        try {
            return jdbc.queryForMap("CALL sp_dashboard_admin_get_by_id(?)", id);
        } catch (EmptyResultDataAccessException ex) {
            return Map.of();
        }
    }

    public void create(String phone, String name, String email, String hash, boolean isSuper) {
        jdbc.update("CALL sp_dashboard_admin_create(?, ?, ?, ?, ?)", phone, name, email, hash, isSuper ? 1 : 0);
    }

    public void updatePassword(long id, String hash) {
        jdbc.update("CALL sp_dashboard_admin_update_password(?, ?)", id, hash);
    }

    public List<Map<String, Object>> list() {
        return jdbc.queryForList("CALL sp_dashboard_admin_list()");
    }
}
