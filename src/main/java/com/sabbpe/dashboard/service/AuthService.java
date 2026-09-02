package com.sabbpe.dashboard.service;

import com.sabbpe.dashboard.repository.AdminAuthRepository;
import org.springframework.http.HttpStatus;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

@Service
public class AuthService {

    private static final Pattern PASSWORD_PATTERN = Pattern.compile("^(?=.*[A-Za-z])(?=.*[0-9]).{8,}$");

    private final AdminAuthRepository repository;
    private final JwtService jwtService;
    private final BCryptPasswordEncoder encoder = new BCryptPasswordEncoder();

    public AuthService(AdminAuthRepository repository, JwtService jwtService) {
        this.repository = repository;
        this.jwtService = jwtService;
    }

    public Map<String, Object> login(String phone, String password) {
        Map<String, Object> admin = repository.getByPhone(normalizePhone(phone));
        if (admin.isEmpty() || !encoder.matches(password, String.valueOf(admin.get("password_hash")))) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Invalid phone number or password");
        }
        if (!isActive(admin)) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Account is inactive");
        }
        String adminId = String.valueOf(admin.get("id"));
        String token = jwtService.generateToken(adminId, String.valueOf(admin.get("phone_number")),
                String.valueOf(admin.get("full_name")));
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("token", token);
        response.put("admin", toAdminView(admin));
        return response;
    }

    public Map<String, Object> validateToken(String adminId) {
        Map<String, Object> admin = repository.getById(Long.parseLong(adminId));
        if (admin.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Admin not found");
        }
        return toAdminView(admin);
    }

    public void changePassword(String adminId, String currentPassword, String newPassword) {
        validatePassword(newPassword);
        Map<String, Object> admin = requireAdmin(adminId);
        if (!encoder.matches(currentPassword, String.valueOf(admin.get("password_hash")))) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Current password is incorrect");
        }
        repository.updatePassword(Long.parseLong(adminId), encoder.encode(newPassword));
    }

    public void resetPassword(String callerAdminId, String phone, String newPassword) {
        requireSuperAdmin(callerAdminId);
        validatePassword(newPassword);
        Map<String, Object> target = repository.getByPhone(normalizePhone(phone));
        if (target.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Admin not found");
        }
        repository.updatePassword(((Number) target.get("id")).longValue(), encoder.encode(newPassword));
    }

    public Map<String, Object> createAdmin(String callerAdminId, String phone, String name,
                                           String email, String password, boolean isSuper) {
        requireSuperAdmin(callerAdminId);
        validatePassword(password);
        Map<String, Object> existing = repository.getByPhone(normalizePhone(phone));
        if (!existing.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "Phone number already exists");
        }
        repository.create(normalizePhone(phone), name, email, encoder.encode(password), isSuper);
        Map<String, Object> created = repository.getByPhone(normalizePhone(phone));
        return toAdminView(created);
    }

    public List<Map<String, Object>> listAdmins(String callerAdminId) {
        requireSuperAdmin(callerAdminId);
        return repository.list();
    }

    private void requireSuperAdmin(String adminId) {
        Map<String, Object> admin = requireAdmin(adminId);
        if (!isSuperAdmin(admin)) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, "Super admin access required");
        }
    }

    private Map<String, Object> requireAdmin(String adminId) {
        Map<String, Object> admin = repository.getById(Long.parseLong(adminId));
        if (admin.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Admin not found");
        }
        if (!isActive(admin)) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Account is inactive");
        }
        return admin;
    }

    private void validatePassword(String password) {
        if (password == null || !PASSWORD_PATTERN.matcher(password).matches()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "Password must be at least 8 characters with at least one letter and one digit");
        }
    }

    private Map<String, Object> toAdminView(Map<String, Object> admin) {
        Map<String, Object> view = new LinkedHashMap<>();
        view.put("id", admin.get("id"));
        view.put("phoneNumber", admin.get("phone_number"));
        view.put("fullName", admin.get("full_name"));
        view.put("email", admin.get("email"));
        view.put("isSuperAdmin", isSuperAdmin(admin));
        return view;
    }

    private boolean isSuperAdmin(Map<String, Object> admin) {
        Object v = admin.get("is_super_admin");
        if (v instanceof Number n) {
            return n.intValue() == 1;
        }
        if (v instanceof Boolean b) {
            return b;
        }
        return false;
    }

    private boolean isActive(Map<String, Object> admin) {
        Object v = admin.get("is_active");
        if (v instanceof Number n) {
            return n.intValue() == 1;
        }
        if (v instanceof Boolean b) {
            return b;
        }
        return true;
    }

    private String normalizePhone(String phone) {
        if (phone == null) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Phone number is required");
        }
        return phone.trim();
    }
}
