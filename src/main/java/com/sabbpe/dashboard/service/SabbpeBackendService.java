package com.sabbpe.dashboard.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.*;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestTemplate;

import java.util.Map;

@Service
public class SabbpeBackendService {

    private static final Logger log = LoggerFactory.getLogger(SabbpeBackendService.class);

    private final RestTemplate restTemplate;
    private final String baseUrl;

    public SabbpeBackendService(
            RestTemplate restTemplate,
            @Value("${sabbpe.backend.base-url:http://localhost:8081}") String baseUrl) {
        this.restTemplate = restTemplate;
        this.baseUrl = baseUrl.replaceAll("/+$", "");
    }

    /**
     * POST /api/v1/rates/live on sabbpegold
     */
    public Map<String, Object> fetchLiveRates() {
        String url = baseUrl + "/api/v1/rates/live";
        log.info("Calling sabbpe backend: {}", url);
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        HttpEntity<Map<String, Object>> request = new HttpEntity<>(Map.of(), headers);
        ResponseEntity<Map> response = restTemplate.exchange(url, HttpMethod.POST, request, Map.class);
        return response.getBody() != null ? response.getBody() : Map.of();
    }

    /**
     * POST /api/v1/orders/buy/create on sabbpegold
     */
    public Map<String, Object> createBuyOrder(Map<String, Object> buyRequest) {
        String url = baseUrl + "/api/v1/orders/buy/create";
        log.info("Calling sabbpe backend: {}", url);
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        HttpEntity<Map<String, Object>> request = new HttpEntity<>(buyRequest, headers);
        ResponseEntity<Map> response = restTemplate.exchange(url, HttpMethod.POST, request, Map.class);
        return response.getBody() != null ? response.getBody() : Map.of();
    }
}
