# HELM-APP POC — Event-Driven Microservices on Kubernetes with Helm

Overview
This project is a hands-on proof of concept (POC) for a microservice system. It’s built with Kubernetes, packaged using Helm, and designed to follow a modular, event-driven architecture. All core components are containerized and deployed across multiple services with built-in observability, messaging, and scalability features.

This setup reflects actual solution architectural patterns, and is based on the Solution Architecture Document created for a system modernization project.

This Proof of Concept (POC) served as a prerequisite to my completed Docker and Kubernetes POC. It laid the groundwork for orchestrating and maintaining Kubernetes clusters, and introduced Helm-based configuration to enable parameterized deployments.

| Component                                      | Description                                                                                                                    |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| ✅ **Helm-based Kubernetes deployment**         | All services are packaged and deployed using Helm charts for consistency and repeatability.                                    |
| 🌐 **ALB-style reverse proxy (Nginx Ingress)** | Simulates AWS ALB behavior, exposing services securely via HTTPS using NodePort.                                               |
| 🛣️ **API Gateway**                            | Acts as the control point for all API requests—supports **rate limiting**, **autoscaling**, and **service routing**.           |
| 📩 **RabbitMQ**                                | Handles asynchronous communication using a pub-sub queue model.                                                                |
| 🔁 **Lambda-style Producers & Consumers**      | Stateless workers that publish and consume events to/from RabbitMQ, simulating background jobs.                                |
| 📊 **Prometheus + Grafana**                    | Monitoring and dashboards with detailed metrics per service.                                                                   |
| 🚨 **AlertManager**                            | Triggers alerts based on Prometheus rules—perfect for ops readiness.                                                           |
| 💾 **PostgreSQL**                              | Main storage engine for persistent data.                                                                                       |
| ⚡ **Redis**                                    | Fast in-memory caching layer for GET requests and temporary data.                                                              |
| 🔒 **HTTPS via Nginx**                         | Simulated TLS termination and reverse proxy setup for secure ingress.                                                          |
| 🛠️ **PowerShell Automation Scripts**          | Automates builds, service validation, load testing, and verification of scalability, observability, performance, and security. |


Components & Ports

| Service                       | Port    | Purpose                                |
| ----------------------------- | ------- | -------------------------------------- |
| Nginx Ingress (simulated ALB) | `31443` | HTTPS access point                     |
| Frontend                      | —       | Simple UI layer                        |
| API Gateway                   | `8081`  | Entry point for all APIs, rate limited |
| Backend API                   | `3000`  | CRUD logic, connects to DB/Redis       |
| RabbitMQ                      | `5672`  | Broker for messaging                   |
| RabbitMQ UI                   | `15672` | Admin interface                        |
| PostgreSQL                    | `5432`  | Relational DB                          |
| Redis                         | `6379`  | Cache                                  |
| Prometheus                    | `9090`  | Metrics collection                     |
| Grafana                       | `3001`  | Visual dashboards                      |
| AlertManager                  | `9093`  | Alerting rules and notification hooks  |


How It Works (End-to-End Process)

| Step | Description |
|------|-------------|
| 🔐 1. HTTPS Access | Users access the app via **HTTPS** through **Nginx Ingress** simulating **ALB**. |
| 🚦 2. API Gateway | Receives requests, enforces **rate limiting**, and forwards them to the right microservice. |
| ⚡ 3. Redis Caching | **GET** requests are cached in **Redis** to boost performance and reduce backend load. |
| 🛠️ 4. Backend Service | Handles **CRUD** operations and manages **cache invalidation** as needed. |
| 📩 5. Event Publishing | **Producers** publish events to **RabbitMQ** for asynchronous processing. |
| 🔁 6. Event Consumption | **Consumers** process events and may call backend endpoints (e.g., `/process`). |
| 📊 7. Metrics | **Prometheus** scrapes service metrics for observability. |
| 📈 8. Visualization | **Grafana** visualizes real-time data via connected dashboards. |
| 🚨 9. Alerts | **AlertManager** triggers alerts based on Prometheus rule thresholds. |

Security Notes

| Concern              | Implementation Details                                                   |
|----------------------|---------------------------------------------------------------------------|
| API Access Control   | API Gateway enforces **CORS** restrictions and **rate limiting**.         |
| Database Protection  | **PostgreSQL** is accessible **only within the cluster** (no public exposure). |
| Traffic Security     | All external traffic is routed through **HTTPS** via **Ingress**.         |
| Messaging Isolation  | **RabbitMQ** is internal-only; **only trusted services** can access it.   |

Author

Built by John Christopher M. Carrillo

Role: Solution Architect

Purpose: For internal POC and architecture validation of a system modernization project.
