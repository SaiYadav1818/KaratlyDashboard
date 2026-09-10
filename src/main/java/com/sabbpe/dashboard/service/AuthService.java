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
import java.security.SecureRandom;

@Service
public class AuthService {

    private static final Pattern PASSWORD_PATTERN = Pattern.compile("^(?=.*[A-Za-z])(?=.*[0-9]).{8,}$");

    private final AdminAuthRepository repository;
    private final BCryptPasswordEncoder encoder = new BCryptPasswordEncoder();
    private final SecureRandom random = new SecureRandom();
    private static final String GENERATED_PASSWORD_CHARS =
            "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

    public AuthService(AdminAuthRepository repository) {
        this.repository = repository;
    }

    public Map<String, Object> login(String phone, String password) {
        Map<String, Object> admin = repository.getByPhone(normalizePhone(phone));
        if (admin.isEmpty() || !encoder.matches(password, String.valueOf(admin.get("password_hash")))) {
            return Map.of("success", false, "message", "Invalid phone number or password");
        }
        if (!isActive(admin)) {
            return Map.of("success", false, "message", "Account is inactive");
        }
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("success", true);
        response.put("admin", toAdminView(admin));
        return response;
    }

    public Map<String, Object> getAdminById(long adminId) {
        Map<String, Object> admin = repository.getById(adminId);
        if (admin.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Admin not found");
        }
        return toAdminView(admin);
    }

    public Map<String, Object> changePassword(long adminId, String existingPassword,
                                               String newPassword, String confirmPassword) {
        if (newPassword == null || !newPassword.equals(confirmPassword)) {
            return Map.of("success", false, "message", "New password and confirmation do not match");
        }
        validatePassword(newPassword);
        Map<String, Object> admin = repository.getById(adminId);
        if (admin.isEmpty() || !isActive(admin)) {
            return Map.of("success", false, "message", "Admin account not found or inactive");
        }
        if (!encoder.matches(existingPassword, String.valueOf(admin.get("password_hash")))) {
            return Map.of("success", false, "message", "Existing password is incorrect");
        }
        repository.updatePassword(adminId, encoder.encode(newPassword));
        return Map.of("success", true, "message", "Password changed successfully");
    }

    public Map<String, Object> forgotPassword(String identifier, String existingPassword) {
        if (identifier == null || identifier.isBlank()) {
            return Map.of("success", false, "message", "Phone number or email is required");
        }
        Map<String, Object> admin = repository.getByPhoneOrEmail(identifier.trim());
        if (admin.isEmpty() || !isActive(admin)) {
            return Map.of("success", false, "message", "Admin account not found or inactive");
        }
        if (!encoder.matches(existingPassword, String.valueOf(admin.get("password_hash")))) {
            return Map.of("success", false, "message", "Existing password is incorrect");
        }
        String generatedPassword = generatePassword();
        repository.updatePassword(((Number) admin.get("id")).longValue(), encoder.encode(generatedPassword));
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("success", true);
        response.put("message", "Password generated successfully");
        response.put("phoneNumber", admin.get("phone_number"));
        response.put("email", admin.get("email"));
        response.put("generatedPassword", generatedPassword);
        return response;
    }

    public Map<String, Object> createAdmin(String phone, String name,
                                           String email, String password, boolean isSuper) {
        validatePassword(password);
        Map<String, Object> existing = repository.getByPhone(normalizePhone(phone));
        if (!existing.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "Phone number already exists");
        }
        repository.create(normalizePhone(phone), name, email, encoder.encode(password), isSuper);
        Map<String, Object> created = repository.getByPhone(normalizePhone(phone));
        return toAdminView(created);
    }

    public List<Map<String, Object>> listAdmins() {
        return repository.list();
    }

    private void validatePassword(String password) {
        if (password == null || !PASSWORD_PATTERN.matcher(password).matches()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "Password must be at least 8 characters with at least one letter and one digit");
        }
    }

    private String generatePassword() {
        StringBuilder password = new StringBuilder(10);
        for (int i = 0; i < 10; i++) {
            password.append(GENERATED_PASSWORD_CHARS.charAt(
                    random.nextInt(GENERATED_PASSWORD_CHARS.length())));
        }
        return password.toString();
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
