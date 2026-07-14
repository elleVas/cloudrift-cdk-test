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
| **NAT Gateway** (optional) | Network | $0.045 | $1.08 | $32.85 |

*Log Group: costs $0.03/GB ingested — with zero logs written, cost is zero.

---

## Totals

| Scenario | Cost/day | Cost/week | Cost/month |
|----------|----------|-----------|------------|
| **Without NAT Gateway** | ~$1.20 | ~$8.40 | ~$36.16 |
| **With NAT Gateway** | ~$2.28 | ~$15.96 | ~$69.01 |

---

## Biggest Cost Drivers

1. **ALB** ($16.43/month) — fixed cost even with no traffic
2. **EC2 running** ($7.59/month) — the idle instance (needed to test `ebs-idle`)
3. **EIP** ($3.60/month) — fixed cost for unassociated IP
4. **DynamoDB** ($3.11/month) — unused provisioned capacity
5. **EBS volumes** (~$3.08/month combined) — billed even when unattached/stopped

---

## Recommendations

1. **Destroy immediately after testing**: `npm run cleanup` (= `cdk destroy --force`)
2. **Don't leave active for days** — costs accumulate
3. **If testing frequently**: use `npm run test:full` which does deploy+validate+destroy
4. **NAT Gateway**: enable only if you need to validate the `nat-gateway` scanner
5. **Free tier**: EC2 t3.micro is covered by free tier for the first 12 months. If your account qualifies, effective cost drops to ~$0.70/day

---

## Why not cheaper resources?

- **t3.micro** is the minimum for EC2 — we need a real instance
- **8–10GB EBS** is the minimum reasonable for a test volume
- **5 RCU/WCU DynamoDB** is the minimum for provisioned mode
- **ALB** has no cheaper alternative — base cost is fixed

---

## Reducing costs during stack development

If you're iterating on the CDK stack itself (not on validation):

```bash
# Deploy only the stack without extras
cdk deploy CloudriftTestStack --exclusively
```

Remember: every `cdk deploy` costs CloudFormation time + active resources until `destroy`.
