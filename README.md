# k8s-observability-pulsehealth
# PulseHealth Observability Platform

Production-grade Kubernetes observability platform with SLO-driven alerting and reproducible infrastructure deployment on AWS EKS.

Status: in progress (Day 1 of 21)

---

# Problem Statement

PulseHealth is a growing healthcare SaaS company experiencing increasing operational instability as platform traffic scales. The operations team currently receives 40+ alerts per week, many of them caused by short-lived infrastructure spikes that resolve before engineers can investigate.

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

---

# SLOs

---

# Dashboards

---

# Runbooks

---

# How to Deploy
