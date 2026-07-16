# Costs — cloudrift-cdk-test

Detailed cost estimate for resources deployed by the stack.

> Prices refer to **us-east-1** (June 2026). Other regions may vary by 5–15%.

---

## Per Resource

| Resource | Type | Cost/hour | Cost/day | Cost/month |
|----------|------|-----------|----------|------------|
| EBS gp2 8GB (unattached) | Volume | — | $0.027 | $0.80 |
| EBS gp3 8GB (unattached) | Volume | — | $0.021 | $0.64 |
| EBS gp3 8GB (stopped EC2 root) | Volume | — | $0.021 | $0.64 |
| EBS gp2 10GB (idle EC2 root) | Volume | — | $0.033 | $1.00 |
| Elastic IP (unassociated) | Network | $0.005 | $0.12 | $3.60 |
| EC2 t3.micro (stopped) | Compute | $0.00 | $0.00 | $0.00 |
| EC2 t3.micro (running, idle) | Compute | $0.0104 | $0.25 | $7.59 |
| ALB (no targets) | Network | $0.0225 | $0.54 | $16.43 |
| Log Group (no retention) | Logs | $0.00 | $0.00 | $0.00* |
| S3 Bucket (empty, no lifecycle) | Storage | $0.00 | $0.00 | $0.00 |
| Lambda (never invoked) | Compute | $0.00 | $0.00 | $0.00 |
| DynamoDB (5 RCU + 5 WCU) | Database | — | $0.10 | $3.11 |
| ENI (orphaned) | Network | $0.00 | $0.00 | $0.00 |
| EBS Snapshot 1GB | Storage | — | $0.002 | $0.05 |
| RDS db.t3.micro (stopped) | Database | $0.00 | $0.00 | $0.00 |
| RDS storage 20GB gp3 (stopped) | Storage | — | $0.053 | $1.60 |
| EFS (near-empty) | Storage | $0.00 | $0.00 | ~$0.00 |
| ElastiCache cache.t4g.micro | Database | $0.016 | $0.38 | $11.68 |
| Redshift dc2.large (1 node) | Database | $0.250 | $6.00 | $182.50 |
| OpenSearch t3.small.search + 10GB | Analytics | $0.037 | $0.89 | $27.08 |
| MSK 2× kafka.t3.small + storage | Streaming | $0.085 | $2.05 | $62.34 |
| FSx for Lustre 1200GiB SCRATCH_2 ⚠️ | Storage | ~$0.233 | ~$5.60 | ~$168 |
| DocumentDB db.t3.medium | Database | $0.077 | $1.85 | $56.21 |
| Neptune db.t3.medium | Database | $0.082 | $1.97 | $59.86 |
| Amazon MQ mq.t3.micro | Messaging | $0.017 | $0.41 | $12.41 |
| VPN Site-to-Site connection | Network | $0.050 | $1.20 | $36.50 |
| Transit Gateway + 1 attachment | Network | $0.050 | $1.20 | $36.50 |
| Kinesis 1 shard (provisioned) | Streaming | $0.015 | $0.36 | $10.95 |
| Secrets Manager (Redshift managed password) | Secret | — | $0.013 | $0.40 |
| **NAT Gateway** (optional) | Network | $0.045 | $1.08 | $32.85 |
| **WorkSpaces + Simple AD** (opt-in) | Compute | ~$0.35 | ~$8.40 | ~$255 |

*Log Group: costs $0.03/GB ingested — with zero logs written, cost is zero.

⚠️ FSx for Lustre throughput-capacity pricing is a best-effort estimate, not independently verified — check your first bill before relying on it for planning (see `docs/en/ARCHITECTURE.md` Known Limitations).

---

## Totals

These are monthly-equivalent figures (useful for comparing resources), not what a real test costs — see "What a real test cycle actually costs" below for that.

| Scenario | Cost/day | Cost/week | Cost/month |
|----------|----------|-----------|------------|
| **Base stack only** (pre-existing resources, no NAT) | ~$1.20 | ~$8.40 | ~$36.16 |
| **Base stack + NAT Gateway** | ~$2.28 | ~$15.96 | ~$69.01 |
| **Full stack** (base + all vertical scanners, no WorkSpaces) | ~$22.30 | ~$156.10 | ~$677 |
| **Full stack + WorkSpaces** | ~$30.70 | ~$214.90 | ~$932 |

---

## What a real test cycle actually costs

The totals above assume a resource stays up for a full day/week/month — but the intended workflow is `npm run test:full` (deploy → post-deploy → wait 5min → validate → you run `npm run cleanup`), a cycle of roughly 1-2 hours once you account for MSK/DocumentDB/Neptune/Redshift/OpenSearch provisioning time. At the **full stack** hourly rate (~$0.93/hour combined), a 2-hour test cycle costs **under $2**. Cost only becomes a real concern if the stack is left running for days — always run `npm run cleanup` right after validating.

---

## Biggest Cost Drivers

1. **FSx for Lustre** (~$168/month) — 1200 GiB is the practical minimum for SCRATCH_2, no smaller Lustre tier exists
2. **Redshift** (~$182.50/month) — dc2.large is the smallest node type available, no "micro" option
3. **MSK** (~$62.34/month) — 2 brokers is the minimum for a 2-AZ provisioned cluster
4. **Neptune** (~$59.86/month) — db.t3.medium is the smallest instance class, no "micro" tier
5. **DocumentDB** (~$56.21/month) — same constraint as Neptune, no "micro" tier
6. **ALB** ($16.43/month) — fixed cost even with no traffic

---

## Recommendations

1. **Destroy immediately after testing**: `npm run cleanup` (= `cdk destroy --force`)
2. **Don't leave active for days** — costs accumulate
3. **If testing frequently**: use `npm run test:full` which does deploy+validate+destroy
4. **NAT Gateway**: enable only if you need to validate the `nat-gateway` scanner
5. **WorkSpaces**: enable only if you need to validate `workspaces-idle` — it's the single biggest cost driver by far and the slowest to provision
6. **Free tier**: EC2 t3.micro and RDS db.t3.micro are covered by free tier for the first 12 months. If your account qualifies, effective cost drops accordingly

---

## Why not cheaper resources?

- **t3.micro** is the minimum for EC2/RDS — we need a real instance
- **8–10GB EBS** is the minimum reasonable for a test volume
- **5 RCU/WCU DynamoDB** is the minimum for provisioned mode
- **ALB** has no cheaper alternative — base cost is fixed
- **dc2.large** is the smallest Redshift node type — no smaller provisioned option exists
- **db.t3.medium** is the smallest instance class DocumentDB and Neptune support — neither offers a "micro" tier
- **1200 GiB** is the practical minimum for FSx for Lustre SCRATCH_2 — chosen over FSx for Windows specifically to avoid requiring an Active Directory (see `docs/en/ARCHITECTURE.md`)

---

## Reducing costs during stack development

If you're iterating on the CDK stack itself (not on validation):

```bash
# Deploy only the stack without extras
cdk deploy CloudriftTestStack --exclusively
```

Remember: every `cdk deploy` costs CloudFormation time + active resources until `destroy`.
