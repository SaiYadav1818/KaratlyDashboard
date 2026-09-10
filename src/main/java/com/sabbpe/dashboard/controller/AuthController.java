package com.sabbpe.dashboard.controller;

import com.sabbpe.dashboard.service.AuthService;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

@RestController
@RequestMapping("/api/v1/admin/auth")
public class AuthController {

    private final AuthService authService;

    public AuthController(AuthService authService) {
        this.authService = authService;
    }

    public record LoginRequest(String phoneNumber, String password) {}
    public record ChangePasswordRequest(Long adminId, String existingPassword,
                                        String newPassword, String confirmPassword) {}
    public record ForgotPasswordRequest(String identifier, String existingPassword) {}
    public record CreateAdminRequest(String phoneNumber, String fullName, String email,
                                     String password, boolean isSuperAdmin) {}

    @PostMapping("/login")
    public Map<String, Object> login(@RequestBody LoginRequest request) {
        return authService.login(request.phoneNumber(), request.password());
    }

    @PostMapping("/change-password")
    public Map<String, Object> changePassword(@RequestBody ChangePasswordRequest request) {
        if (request.adminId() == null) {
            return Map.of("success", false, "message", "adminId is required");
        }
        return authService.changePassword(request.adminId(), request.existingPassword(),
                request.newPassword(), request.confirmPassword());
    }

    @PostMapping("/forgot-password")
    public Map<String, Object> forgotPassword(@RequestBody ForgotPasswordRequest request) {
        return authService.forgotPassword(request.identifier(), request.existingPassword());
    }

    @PostMapping("/admin")
    public Map<String, Object> getAdmin(@RequestBody Map<String, Object> request) {
        long adminId = ((Number) request.get("adminId")).longValue();
        return authService.getAdminById(adminId);
    }

    @PostMapping("/create-admin")
    public Map<String, Object> createAdmin(@RequestBody CreateAdminRequest request) {
        Map<String, Object> admin = authService.createAdmin(request.phoneNumber(),
                request.fullName(), request.email(), request.password(), request.isSuperAdmin());
        return Map.of("success", true, "admin", admin);
    }

    @GetMapping("/admins")
    public Map<String, Object> listAdmins() {
        return Map.of("admins", authService.listAdmins());
    }
}
