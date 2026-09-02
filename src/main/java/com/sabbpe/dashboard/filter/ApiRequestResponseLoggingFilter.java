package com.sabbpe.dashboard.filter;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.util.ContentCachingRequestWrapper;
import org.springframework.web.util.ContentCachingResponseWrapper;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 20)
public class ApiRequestResponseLoggingFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(ApiRequestResponseLoggingFilter.class);
    private static final int MAX_PAYLOAD_LENGTH = 4096;
    private static final Pattern SENSITIVE_JSON_FIELDS = Pattern.compile(
            "(?i)(\"(?:password|passwordHash|otp|token|accessToken|refreshToken|authorization|apiKey|apiSecret|sessionToken)\"\\s*:\\s*\")([^\"]*)(\")");
    private static final Pattern SENSITIVE_FORM_FIELDS = Pattern.compile(
            "(?i)((?:password|passwordHash|otp|token|accessToken|refreshToken|authorization|apiKey|apiSecret|sessionToken)=)([^&\\s]*)");
    private static final List<String> VISIBLE_CONTENT_TYPES = List.of(
            MediaType.APPLICATION_JSON_VALUE,
            MediaType.APPLICATION_FORM_URLENCODED_VALUE,
            MediaType.TEXT_PLAIN_VALUE,
            MediaType.TEXT_XML_VALUE,
            MediaType.APPLICATION_XML_VALUE);

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return !request.getRequestURI().startsWith("/api/");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        String requestId = UUID.randomUUID().toString();
        MDC.put("requestId", requestId);

        ContentCachingRequestWrapper wrappedRequest = new ContentCachingRequestWrapper(request, MAX_PAYLOAD_LENGTH);
        ContentCachingResponseWrapper wrappedResponse = new ContentCachingResponseWrapper(response);
        long startNanos = System.nanoTime();

        try {
            filterChain.doFilter(wrappedRequest, wrappedResponse);
        } finally {
            long durationMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNanos);
            logRequestAndResponse(wrappedRequest, wrappedResponse, requestId, durationMs);
            wrappedResponse.copyBodyToResponse();
            MDC.remove("requestId");
        }
    }

    private void logRequestAndResponse(
            ContentCachingRequestWrapper request,
            ContentCachingResponseWrapper response,
            String requestId,
            long durationMs) {
        String requestBody = extractPayload(
                request.getContentAsByteArray(),
                request.getCharacterEncoding(),
                request.getContentType());
        String responseBody = extractPayload(
                response.getContentAsByteArray(),
                response.getCharacterEncoding(),
                response.getContentType());

        log.info(
                "API request completed requestId={} method={} path={} query={} status={} durationMs={} requestBody={} responseBody={}",
                requestId,
                request.getMethod(),
                request.getRequestURI(),
                defaultValue(request.getQueryString()),
                response.getStatus(),
                durationMs,
                requestBody,
                responseBody);
    }

    private String extractPayload(byte[] content, String encoding, String contentType) {
        if (content == null || content.length == 0) {
            return "<empty>";
        }
        if (!isVisibleContentType(contentType)) {
            return "<" + defaultValue(contentType) + " payload omitted>";
        }

        Charset charset = resolveCharset(encoding);
        String value = new String(content, charset);
        String sanitized = sanitize(value);
        if (sanitized.length() > MAX_PAYLOAD_LENGTH) {
            return sanitized.substring(0, MAX_PAYLOAD_LENGTH) + "...<truncated>";
        }
        return sanitized;
    }

    private boolean isVisibleContentType(String contentType) {
        if (contentType == null || contentType.isBlank()) {
            return true;
        }
        String normalized = contentType.toLowerCase();
        for (String visibleContentType : VISIBLE_CONTENT_TYPES) {
            if (normalized.contains(visibleContentType)) {
                return true;
            }
        }
        return normalized.startsWith("text/");
    }

    private Charset resolveCharset(String encoding) {
        if (encoding == null || encoding.isBlank()) {
            return StandardCharsets.UTF_8;
        }
        try {
            return Charset.forName(encoding);
        } catch (Exception ignored) {
            return StandardCharsets.UTF_8;
        }
    }

    private String sanitize(String value) {
        String maskedJson = SENSITIVE_JSON_FIELDS.matcher(value).replaceAll("$1***$3");
        return SENSITIVE_FORM_FIELDS.matcher(maskedJson).replaceAll("$1***");
    }

    private String defaultValue(String value) {
        return value == null || value.isBlank() ? "-" : value;
    }
}
