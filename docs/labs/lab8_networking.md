# Lab 8 — Networking: VPC, Subnets, and Docker Networks

**Prereqs:** Labs 1, 5 complete. Docker stack running.
**Time:** 30-40 minutes
**Goal:** Understand network segmentation, how containers communicate, and how VPC design maps to a trading firm's security requirements.

---

## Why This Matters

Trading firms handle sensitive financial data. Network segmentation ensures:
- The **trading system** (MSSQL, Go service) can't be reached from the public internet
- The **market data feed** runs on a separate subnet from **internal tools** (Grafana, Superset)
- **Zscaler** (or equivalent) controls which users can access which network segments
- A compromised BI tool can't directly access the trade database

On the job, you'll see VPCs, subnets, security groups, and network ACLs in Terraform. This lab teaches the concepts using Docker networks as a local analogue.

---

## Part A — Understand Docker Networking (10 min)

### Task A1: See the current network
```bash
# List all Docker networks
docker network ls

# Inspect the default network used by our stack
docker network inspect inthesauce_default
```

Note: All containers are on the same network. Every container can reach every other container by hostname (e.g. `mssql`, `clickhouse`, `kafka`).

**Question:** Is this good for production? (Answer: No. In production, you'd isolate databases from public-facing services. A compromised Superset container shouldn't be able to reach Kafka directly.)

### Task A2: Test inter-container connectivity
```bash
# From the ClickHouse container, can we reach MSSQL?
docker exec etrm-clickhouse bash -c "cat /dev/null > /dev/tcp/mssql/1433 && echo 'Can reach MSSQL' || echo 'Cannot reach MSSQL'"

# From Superset, can we reach Kafka?
docker exec etrm-superset bash -c "cat /dev/null > /dev/tcp/kafka/29092 && echo 'Can reach Kafka' || echo 'Cannot reach Kafka'" 2>/dev/null || echo "Test failed (tool not available in container)"
```

Currently, everything can talk to everything. That's convenient for a sandbox but insecure for production.

### Task A3: Understand DNS resolution in Docker
```bash
# Containers resolve each other by service name
docker exec etrm-clickhouse ping -c 2 mssql
docker exec etrm-clickhouse ping -c 2 kafka
```

Docker's built-in DNS maps service names to container IPs. This is why `docker-compose.yml` uses hostnames like `mssql:1433` instead of IP addresses.

---

## Part B — Design a Segmented Network (15 min)

### Task B1: Map the architecture to subnets

In a real AWS deployment, the ETRM stack would be split across subnets:

```
VPC: 10.124.0.0/16 (ETRM Production)
│
├── Public Subnet: 10.124.1.0/24
│   └── Load Balancer (ALB) — only thing exposed to the internet
│
├── App Subnet: 10.124.10.0/24
│   ├── Go Service (EKS pods)
│   ├── Superset
│   └── Grafana
│
├── Data Subnet: 10.124.20.0/24
│   ├── MSSQL (RDS)
│   ├── ClickHouse (EC2 or EKS)
│   └── Redis (ElastiCache)
│
├── Messaging Subnet: 10.124.30.0/24
│   └── Kafka (MSK or EKS)
│
└── Management Subnet: 10.124.40.0/24
    ├── Prometheus
    └── Bastion host (SSH jump box)
```

**Questions:**
1. Why is the Load Balancer in a separate public subnet?
2. Why can't Superset be in the same subnet as MSSQL?
3. What is a bastion host and why does the management subnet need one?

### Task B2: Understand security groups (firewall rules)

Security groups control which traffic is allowed between subnets:

| From | To | Port | Allow? | Why |
|------|----|------|--------|-----|
| ALB | Go Service | 8080 | Yes | Route HTTP traffic |
| Go Service | MSSQL | 1433 | Yes | Read/write trades |
| Go Service | ClickHouse | 9000 | Yes | Read/write P&L data |
| Go Service | Kafka | 9092 | Yes | Produce/consume events |
| Superset | MSSQL | 1433 | Yes | Query trade data |
| Superset | ClickHouse | 8123 | Yes | Query P&L data |
| Superset | Kafka | 9092 | **No** | BI tools don't need messaging |
| Grafana | Prometheus | 9090 | Yes | Query metrics |
| Grafana | MSSQL | 1433 | Yes | SQL panels |
| Internet | MSSQL | 1433 | **No** | Never expose DB to internet |
| Internet | ClickHouse | 8123 | **No** | Never expose DB to internet |
| Internet | Kafka | 9092 | **No** | Never expose messaging to internet |

### Task B3: Simulate network isolation with Docker

Create isolated Docker networks and observe what breaks:

```bash
# Create two separate networks
docker network create etrm-data
docker network create etrm-app

# Connect MSSQL and ClickHouse to the data network
docker network connect etrm-data etrm-mssql
docker network connect etrm-data etrm-clickhouse

# Connect Superset to the app network only
docker network connect etrm-app etrm-superset
```

Now test: can Superset still reach MSSQL?
```bash
# Superset is on both the default network AND etrm-app
# It can still reach MSSQL via the default network
# To truly isolate, you'd need to disconnect from the default network
# (don't do this — it will break the sandbox)
```

**Important:** Don't disconnect containers from the default network — it will break the sandbox. The key takeaway: network isolation is enforced at the infrastructure level (AWS VPC + security groups), not at the Docker level in development.

Clean up:
```bash
docker network disconnect etrm-data etrm-mssql 2>/dev/null
docker network disconnect etrm-data etrm-clickhouse 2>/dev/null
docker network disconnect etrm-app etrm-superset 2>/dev/null
docker network rm etrm-data etrm-app 2>/dev/null
```

### Task B4: Design network segmentation for Docker Compose

In production, you'd split services across named networks. Study this pattern:

```yaml
# What proper network segmentation looks like in Docker Compose
# (don't apply this — it's for understanding)
networks:
  data-tier:    # databases only
  app-tier:     # services that talk to databases
  messaging:    # Kafka
  monitoring:   # Prometheus + Grafana

services:
  mssql:
    networks: [data-tier]            # only reachable from data-tier
  clickhouse:
    networks: [data-tier]
  trade-service:
    networks: [app-tier, data-tier, messaging]  # can reach DBs AND Kafka
  superset:
    networks: [app-tier, data-tier]  # can reach DBs but NOT Kafka
  kafka:
    networks: [messaging]            # isolated from everything except consumers
  grafana:
    networks: [monitoring, data-tier] # can reach DBs for SQL panels
```

**Exercise:** For each service in our `docker-compose.yml`, decide which network(s) it should be on. Ask: "Does Superset need to reach Kafka? Does Grafana need to reach Kafka? Should the MDM Postgres be reachable from Superset?" The answers define your security groups.

---

## Part C — VPC in Terraform (Conceptual) (10 min)

### Task C1: Read VPC Terraform config

In production, VPC resources would look like this (conceptual — LocalStack free tier doesn't support VPC):

```hcl
# This is what it looks like in real Terraform — read and understand, don't apply
resource "aws_vpc" "etrm" {
  cidr_block = "10.124.0.0/16"
  tags       = { Name = "etrm-production" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.etrm.id
  cidr_block        = "10.124.1.0/24"
  availability_zone = "ap-southeast-1a"
  tags              = { Name = "etrm-public" }
}

resource "aws_subnet" "app" {
  vpc_id            = aws_vpc.etrm.id
  cidr_block        = "10.124.10.0/24"
  availability_zone = "ap-southeast-1a"
  tags              = { Name = "etrm-app" }
}

resource "aws_subnet" "data" {
  vpc_id            = aws_vpc.etrm.id
  cidr_block        = "10.124.20.0/24"
  availability_zone = "ap-southeast-1a"
  tags              = { Name = "etrm-data" }
}

resource "aws_security_group" "data_sg" {
  name        = "etrm-data-sg"
  vpc_id      = aws_vpc.etrm.id

  # Allow app subnet to reach MSSQL
  ingress {
    from_port   = 1433
    to_port     = 1433
    protocol    = "tcp"
    cidr_blocks = ["10.124.10.0/24"]  # app subnet only
  }

  # Allow app subnet to reach ClickHouse
  ingress {
    from_port   = 8123
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["10.124.10.0/24"]
  }

  # Deny everything else by default (implicit in AWS)
}
```

### Task C2: Subnet math
Understanding CIDR notation is required on the job:

| CIDR | Subnet Mask | Usable IPs | Use Case |
|------|------------|------------|----------|
| `/16` | 255.255.0.0 | 65,534 | Entire VPC |
| `/24` | 255.255.255.0 | 254 | One subnet (most common) |
| `/27` | 255.255.255.224 | 30 | Small subnet (e.g. bastion) |
| `/28` | 255.255.255.240 | 14 | Very small (NAT gateway) |

**Exercise:** Given `10.124.0.0/16`:
1. How many `/24` subnets can you fit? (Answer: 256)
2. What is the range of `10.124.20.0/24`? (Answer: 10.124.20.1 to 10.124.20.254)
3. Can `10.124.10.5` (app subnet) reach `10.124.20.10` (data subnet) without a security group rule? (Answer: No — security groups deny by default)

---

## Part D — Zscaler Concepts (5 min)

Zscaler is the firm's zero-trust network access (ZTNA) tool. It controls:

| Zscaler Component | What It Does | Sandbox Equivalent |
|---|---|---|
| **Zscaler Private Access (ZPA)** | Controls which users can access which internal apps | Docker network (all allowed in sandbox) |
| **Zscaler Internet Access (ZIA)** | Filters outbound internet traffic (block malware, data exfil) | Not simulated |
| **App Connector** | Sits in the VPC, brokers connections from ZPA to internal services | Not simulated |

**Key concept:** With Zscaler, even VPN isn't needed. A trader's laptop connects to Superset via Zscaler ZPA, which validates their identity (via Microsoft Entra ID), checks their device posture, and creates a micro-tunnel directly to the Superset service in the App subnet. They never get broad network access.

**Question:** Why is this better than a traditional VPN? (Answer: VPN gives you access to an entire network. Zscaler gives you access to specific applications only. If a trader's laptop is compromised, the attacker can only reach Superset — not MSSQL directly.)

---

## Checkpoint: What You Should Be Able to Do

- [ ] List Docker networks and explain how containers discover each other
- [ ] Draw a VPC diagram with public, app, data, and management subnets
- [ ] Explain what a security group is and write a rule that allows app→data traffic
- [ ] Calculate usable IPs for a given CIDR block
- [ ] Design Docker Compose network segmentation (which services go on which networks)
- [ ] Explain the difference between Zscaler ZPA and a traditional VPN
- [ ] Explain why network segmentation matters for a trading firm

---

## Reflection Questions

1. **Incident scenario:** An attacker gains access to the Grafana container (weak admin password). What data can they access? How does network segmentation limit the blast radius?

2. **Architecture decision:** Should the market data scraper (which calls external JEPX/AEMO APIs) be in the same subnet as the trading database? Why or why not?

3. **On the job:** A new developer needs SSH access to debug ClickHouse in production. How should they get access? (Answer: Through the bastion host in the management subnet, with access controlled by Zscaler ZPA and logged to the audit trail.)
