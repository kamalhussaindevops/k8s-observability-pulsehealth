# k8s-observability-pulsehealth
# PulseHealth Observability Platform

Production-grade Kubernetes observability platform with SLO-driven alerting and reproducible infrastructure deployment on AWS EKS.

Status: in progress (Day 1 of 21)

---

# Problem Statement

PulseHealth is a growing healthcare SaaS company experiencing increasing operational instability as platform traffic scales. The operations team currently receives 40+ pages a week, half of them at 3am for issues that resolve themselves before anyone can investigate.

More critically, the platform lacks reliable user-centric observability. During a recent production incident, degraded API response performance went undetected internally for 17 minutes until multiple customer support reports were received.

The company requires a reproducible observability platform capable of:

* reducing alert fatigue
* introducing SLO-driven monitoring
* improving incident visibility
* standardizing operational practices
* enabling on-demand AWS EKS deployments

---

# Project Approach

This project is designed as a reusable observability platform rather than a one-off environment setup. The platform will use Kubernetes-native tooling, Infrastructure as Code, and SRE principles to create a reproducible monitoring stack deployable into AWS EKS environments on demand.

The implementation will focus on:

* Prometheus-based metrics collection
* Grafana dashboards
* SLO-driven alerting
* Infrastructure reproducibility with Terraform
* Helm-based Kubernetes package management
* Operational documentation and runbooks

---

# Architecture

Coming in Week 1 — initial system architecture and deployment flow.

# SLOs

Coming in Week 2 — initial SLO definitions, SLIs, and error-budget strategy.

# Dashboards

Coming in Week 2 — Grafana dashboard structure and key service views.

# Runbooks

Coming in Week 3 — incident response runbooks for common failure modes.

# How to Deploy

Coming in Week 1 — local KIND deployment first, then AWS EKS deployment path.
