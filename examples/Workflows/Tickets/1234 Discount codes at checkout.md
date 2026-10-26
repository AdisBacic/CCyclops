---
type: ticket
ticket: 1234
status: review
repo: shop
updated: 2026-10-20
---

# 1234 Discount codes at checkout

## What it is

Customers can enter a discount code at checkout: a percentage or a fixed amount, one code per order, with expiry and usage limits set in the admin.

## Work log

### 2026-10-19 10:12 — session (shop)
- branch: `feature/1234-discount-codes`
- topic: validate expired and used-up discount codes, with tests
- commits today:
    - `a41c9e2 Validate discount code expiry and usage limit`
    - `7d03b18 Test expired and exhausted codes`
- files touched:
    - `src/checkout/discounts.test.ts`
    - `src/checkout/discounts.ts`

### 2026-10-20 09:47 — session (shop)
- branch: `feature/1234-discount-codes`
- topic: address the review comments on the discount code PR
- commits today:
    - `c2e8f51 Show why a code was rejected`
- files touched:
    - `src/checkout/DiscountField.tsx`
    - `src/checkout/discounts.ts`
