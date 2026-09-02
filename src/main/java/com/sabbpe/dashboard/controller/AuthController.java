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
    public record ChangePasswordRequest(String currentPassword, String newPassword) {}
    public record ResetPasswordRequest(String phoneNumber, String newPassword) {}
    public record CreateAdminRequest(String phoneNumber, String fullName, String email,
                                     String password, boolean isSuperAdmin) {}

    @PostMapping("/login")
    public Map<String, Object> login(@RequestBody LoginRequest request) {
        return authService.login(request.phoneNumber(), request.password());
    }

    @PostMapping("/validate-token")
    public Map<String, Object> validateToken(@RequestAttribute("adminId") String adminId) {
        return authService.validateToken(adminId);
    }

    @PostMapping("/change-password")
    public Map<String, Object> changePassword(@RequestAttribute("adminId") String adminId,
                                              @RequestBody ChangePasswordRequest request) {
        authService.changePassword(adminId, request.currentPassword(), request.newPassword());
        return Map.of("success", true, "message", "Password changed");
    }

    @PostMapping("/reset-password")
    public Map<String, Object> resetPassword(@RequestAttribute("adminId") String adminId,
                                             @RequestBody ResetPasswordRequest request) {
        authService.resetPassword(adminId, request.phoneNumber(), request.newPassword());
        return Map.of("success", true, "message", "Password reset");
    }

    @PostMapping("/create-admin")
    public Map<String, Object> createAdmin(@RequestAttribute("adminId") String adminId,
                                           @RequestBody CreateAdminRequest request) {
        Map<String, Object> admin = authService.createAdmin(adminId, request.phoneNumber(),
                request.fullName(), request.email(), request.password(), request.isSuperAdmin());
        return Map.of("success", true, "admin", admin);
    }

    @GetMapping("/admins")
    public Map<String, Object> listAdmins(@RequestAttribute("adminId") String adminId) {
        return Map.of("admins", authService.listAdmins(adminId));
    }
}
