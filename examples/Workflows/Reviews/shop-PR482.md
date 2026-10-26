---
type: pr-review
repo: acme/shop
pr: 482
head_sha: 9f3c1e7a2b8d4f60c5e1a9b7d3f2e8c4a6b0d1f9
reviewed: 2026-10-20
---

# acme/shop#482 — Store prices as integer cents

**What it does:** Moves `products.price` and `order_lines.unit_price` from decimal euros to integer cents, with a migration that converts existing rows and a `formatMoney` helper for display. Checkout totals now add integers instead of floats.

**Verdict:** ⚠️ has findings

## Findings

### 🔴 Critical
- –

### 🟠 High
- `migrations/2026-10-19-prices-to-cents.ts:14` — converts with `Math.trunc(row.price * 100)`, and `19.99 * 100` is `1998.9999999999998` in floating point, so 19.99 is stored as 1998. Every price that doesn't survive the float round-trip loses a cent, permanently. Use `Math.round(row.price * 100)`, or convert in SQL with `ROUND(price * 100)`.

### 🟡 Medium
- `src/checkout/discounts.ts:41` — fixed-amount codes still compare `amountOff` (euros) against `order.total` (now cents), so a 5.00 code takes 5 cents off. No test covers a fixed-amount code, which is why CI is green.
- `migrations/2026-10-19-prices-to-cents.ts` has no `down()` — rolling back a failed deploy leaves prices in cents under code that reads euros.

## Review focus
- The migration: run it on a staging copy and diff a few hundred prices before and after.
- `applyDiscount` in `src/checkout/discounts.ts`, and the missing fixed-amount test.
- Other readers of `price`: `src/feeds/google-shopping.ts` still formats it as euros.
