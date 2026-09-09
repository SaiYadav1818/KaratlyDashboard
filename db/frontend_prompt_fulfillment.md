# Gold Fulfillment Request API — Frontend Prompt

## Overview
Two-level admin system for handling gold fulfillment requests.

- **Level 1 (Regular Admin)**: Views unfulfilled orders, sends requests to Level 2
- **Level 2 (Super Admin)**: Receives requests, approves/rejects/processes them

---

## Authentication
All endpoints require a valid JWT token in the `Authorization` header:
```
Authorization: Bearer <token>
```

The token is obtained from the existing login endpoint:
```
POST /api/v1/admin/auth/login
Body: { "phoneNumber": "...", "password": "..." }
Response: { "token": "...", "admin": { "id", "phoneNumber", "fullName", "email", "isSuperAdmin" } }
```

**Important**: The `isSuperAdmin` field in the login response determines what the admin can do:
- `isSuperAdmin: false` → Level 1 (can only view and send requests)
- `isSuperAdmin: true` → Level 2 (can approve, reject, process)

---

## Level 1 Admin Endpoints

### 1. View Unfulfilled Orders (who paid but didn't get gold)
```
POST /api/v1/admin/dashboard/unfulfilled-cashfree
Headers: Authorization: Bearer <token>
Body: { "days": 90, "status": "ALL" }
Response: {
  "orders": [
    {
      "sabbpe_order_id": "...",
      "merchant_order_id": "...",
      "customer_id": "...",
      "customer_name": "...",
      "customer_mobile": "...",
      "order_amount": 5000.00,
      "order_status": "...",
      "fulfillment_status": "...",
      "payment_status": "SUCCESS",
      "cf_payment_id": "...",
      "provider_reference": "...",
      "created_at": "2026-09-01 10:30:00"
    }
  ]
}
```

### 2. Send Request to Level 2 (for a specific order)
```
POST /api/v1/admin/fulfillment/create
Headers: Authorization: Bearer <token>
Body: {
  "sabbpeOrderId": "ORDER_123",
  "customerId": "CLIENT_456",
  "customerName": "Rahul Sharma",
  "customerMobile": "9876543210",
  "orderAmount": 5000.00,
  "level1Note": "User paid but gold not received. Please process."
}
Response: {
  "success": true,
  "request_id": 1,
  "message": "Request sent to Level 2 admin"
}
```

### 3. View My Requests (requests I sent)
```
GET /api/v1/admin/fulfillment/mine
Headers: Authorization: Bearer <token>
Response: {
  "requests": [
    {
      "id": 1,
      "sabbpe_order_id": "ORDER_123",
      "customer_id": "CLIENT_456",
      "customer_name": "Rahul Sharma",
      "customer_mobile": "9876543210",
      "order_amount": 5000.00,
      "status": "PENDING",
      "level1_note": "User paid but gold not received.",
      "level2_note": null,
      "assigned_to_name": null,
      "created_at": "2026-09-01 10:30:00",
      "updated_at": "2026-09-01 10:30:00"
    }
  ]
}
```

---

## Level 2 Admin Endpoints

### 4. View All Pending Requests (from Level 1)
```
GET /api/v1/admin/fulfillment/pending
Headers: Authorization: Bearer <token>
Response: {
  "requests": [
    {
      "id": 1,
      "sabbpe_order_id": "ORDER_123",
      "customer_id": "CLIENT_456",
      "customer_name": "Rahul Sharma",
      "customer_mobile": "9876543210",
      "order_amount": 5000.00,
      "status": "PENDING",
      "level1_note": "User paid but gold not received.",
      "level2_note": null,
      "created_by_name": "John Admin",
      "created_at": "2026-09-01 10:30:00",
      "updated_at": "2026-09-01 10:30:00"
    }
  ]
}
```

### 5. Approve a Request
```
POST /api/v1/admin/fulfillment/1/approve
Headers: Authorization: Bearer <token>
Body: { "note": "Approving, will process gold purchase" }
Response: {
  "success": true,
  "request": {
    "id": 1,
    "sabbpe_order_id": "ORDER_123",
    "status": "APPROVED"
  }
}
```

### 6. Reject a Request
```
POST /api/v1/admin/fulfillment/1/reject
Headers: Authorization: Bearer <token>
Body: { "note": "Cannot process, amount mismatch" }
Response: {
  "success": true,
  "request": {
    "id": 1,
    "sabbpe_order_id": "ORDER_123",
    "status": "REJECTED"
  }
}
```

### 7. Mark as Processed (gold actually sent)
```
POST /api/v1/admin/fulfillment/1/process
Headers: Authorization: Bearer <token>
Body: { "note": "Gold purchased successfully via Augmont" }
Response: {
  "success": true,
  "request": {
    "id": 1,
    "sabbpe_order_id": "ORDER_123",
    "status": "PROCESSED"
  }
}
```

---

## Request Status Flow
```
PENDING → APPROVED → PROCESSED
PENDING → REJECTED
```

---

## Frontend UI Flow

### Level 1 Admin Dashboard
1. Show unfulfilled orders table (from `/unfulfilled-cashfree`)
2. Each row has a "Send Request" button
3. Click → opens modal to fill note → submit → creates fulfillment request
4. "My Requests" tab shows all requests sent by this admin with status badges

### Level 2 Admin Dashboard
1. Show pending requests table (from `/fulfillment/pending`)
2. Each row has "Approve", "Reject", and "Process" buttons
3. Approve → opens modal for note → submit
4. After approval, "Process" button becomes active
5. Process → opens modal for note → submit → marks as PROCESSED

---

## SQL to Execute
Run `execute_part8_fulfillment_requests.sql` on the production database before using these APIs.

---

## Files Created
- `db/execute_part8_fulfillment_requests.sql` — table + 6 stored procedures
- `GoldFulfillmentRepository.java` — DB calls
- `GoldFulfillmentService.java` — business logic with super admin checks
- `GoldFulfillmentController.java` — 6 REST endpoints
