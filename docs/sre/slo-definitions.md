# PulseHealth Service Level Objectives (SLOs)

**Status:** v1.0
**Owner:** Platform Engineering
**Last reviewed:** 2026-05-18

## Purpose

This document defines the three Service Level Objectives (SLOs) for the PulseHealth platform. SLOs translate engineering reliability into terms the business can act on: how often the system meets user expectations, and how much room we have to take risks before service quality degrades.

These SLOs follow Google SRE methodology. They are designed to be defended in front of engineering, product, and the executive team — not just monitored from a dashboard.

## Definitions

| Term | Meaning |
|------|---------|
| **SLI** | Service Level Indicator. The metric we measure (e.g. % of requests that succeed). |
| **SLO** | Service Level Objective. The internal target for an SLI (e.g. 99.5% success). |
| **SLA** | Service Level Agreement. A contractual commitment to customers, usually looser than the SLO. |
| **Error Budget** | The complement of an SLO. If SLO is 99.5%, the error budget is 0.5%. |

---

## SLO #1: Frontend Availability

**SLI:** Proportion of HTTP requests to the `frontend` service that return a non-5xx response.

**SLO:** 99.5% of frontend requests return successfully, measured over a rolling 28-day window.

**Error budget:** 0.5% = approximately 3.6 hours of failure per 30-day month.

**Justification:**
- 99.5% is achievable on commodity infrastructure without expensive HA setups.
- Higher targets (99.9%+) require significantly more investment.
- This SLO is reviewed quarterly as the platform matures.

**Risk if breached:** Users see error pages on the storefront. Customer trust erodes quickly.

---

## SLO #2: Frontend Latency

**SLI:** 95th percentile of HTTP request duration for the `frontend` service.

**SLO:** 95% of frontend requests complete in under 500ms, measured over a rolling 28-day window.

**Error budget:** 5% of requests may exceed 500ms.

**Justification:**
- 500ms aligns with acceptable UX expectations.
- 95th percentile chosen for v1 to remain achievable.
- Latency degradation often appears before outages.

**Risk if breached:** Users perceive the site as slow. Bounce rate increases.

---

## SLO #3: Checkout Success

**SLI:** Proportion of `POST /cart/checkout` requests that return HTTP 200.

**SLO:** 99.5% of checkout requests succeed, measured over a rolling 28-day window.

**Error budget:** 0.5% of checkout attempts.

**Justification:**
- Checkout is the revenue-critical flow.
- Failed checkouts directly impact business revenue.
- 99.5% is realistic given external dependencies.

**Risk if breached:** Direct revenue loss and failed customer orders.

---

## SLO Hierarchy (Priority Order)

1. Checkout Success
2. Frontend Availability
3. Frontend Latency

Checkout is protected first during incidents because it directly impacts revenue.

## Error Budget Policy

When 50% of the error budget is consumed:
- Engineering reviews recent changes
- Risky deployments are paused

When 90% of the error budget is consumed:
- Non-critical deployments stop
- Reliability work takes priority
- Post-incident review becomes mandatory

## Review Cadence

- Weekly: burn-rate review
- Monthly: leadership SLO review
- Quarterly: SLO target reassessment

## Out of Scope (v2)

- Internal service SLOs
- Distributed tracing SLOs
- External customer SLA
