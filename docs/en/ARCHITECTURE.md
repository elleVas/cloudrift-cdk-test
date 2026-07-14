# Architecture — cloudrift-cdk-test

## Goal

Validate that cloudrift correctly detects wasted AWS resources on a real account (not localstack), with a reproducible and cost-controlled deployment.

---

## Design Decisions

### Construct-per-concern pattern

The monolithic stack is split into domain-specific L3 constructs:

| Construct | Responsibility |
|-----------|---------------|
| `Networking` | VPC, EIP, ENI, ALB, NAT Gateway |
| `Compute` | EC2 instances (stopped + idle) |
| `Storage` | EBS volumes, S3 buckets, orphan snapshot CR |
| `Serverless` | Lambda, DynamoDB, CloudWatch Log Groups |

Benefits:
- Clear ownership of resources and IAM policies
- The main stack reads like an architecture diagram
- Each construct is independently testable
- Adding new concerns requires one file + one line in the stack

### Pure CDK, no Nx

| Criterion | Pure CDK | With Nx |
|-----------|----------|---------|
| Setup complexity | Low | High |
| Libraries to orchestrate | 0 | 0 |
| Useful cache | No (1 target) | No |
| Setup time | 2 min | 15+ min |

Conclusion: unjustified overhead for a single-purpose project.

### Single stack

All resources live in `CloudriftTestStack`. No reason to split:
- Same lifecycle (deploy together, destroy together)
- No circular dependencies to break
- Well below the CloudFormation 500-resource limit

### RemovalPolicy.DESTROY everywhere

Every resource has `removalPolicy: cdk.RemovalPolicy.DESTROY` so `cdk destroy` leaves no orphans (S3 buckets, log groups, etc.).

### Post-deploy script for stopped EC2

CDK (CloudFormation) does not support creating EC2 instances in `stopped` state — they start `running`. The script `scripts/post-deploy.sh`:
1. Reads instance IDs from CloudFormation outputs
2. Stops EC2 with `aws ec2 stop-instances` + `wait`

### Custom Resource for orphan EBS Snapshot

cloudrift detects snapshots whose source volume no longer exists. This isn't expressible with native CDK resources because:
- If you create volume + snapshot in the stack, the volume still exists
- If you delete the volume from the stack, CloudFormation also deletes the snapshot (dependency)

Solution: a Lambda Custom Resource that:
1. Creates a temporary volume (outside CDK control)
2. Snapshots it
3. Deletes the volume
4. Result: snapshot with `source volume deleted`

On `cdk destroy`, the same Lambda cleans up the snapshot (Delete event).

### Minimal VPC (2 AZs, 0 NAT by default)

- 2 AZs is the minimum for ALB
- 0 NAT Gateways by default (high cost, ~$32/month)
- NAT can be enabled via context (`includeNatGateway: true`) to also test the `nat-gateway` scanner

### Why `--min-age-days 0` in validation

cloudrift has a default grace period of 7 days — newly created resources aren't flagged. For testing we use `--min-age-days 0` to disable it.

---

## Resource → Scanner Mapping

| CDK Construct | Logical ID | cloudrift Scanner | Waste Condition |
|---------------|-----------|-------------------|-----------------|
| `UnattachedGp2Volume` | EBS gp2 8GB | `ebs-volume` | `state: available` |
| `UnattachedGp3Volume` | EBS gp3 8GB | `ebs-volume` | `state: available` |
| `UnassociatedEip` | Elastic IP | `elastic-ip` | Not associated |
| `StoppedInstance` | EC2 t3.micro | `ec2-instance` | `state: stopped` |
| `IdleInstance` (root vol) | EBS gp2 10GB | `ebs-idle` | Attached, zero I/O |
| `IdleInstance` (root vol) | EBS gp2 10GB | `ebs-gp2-upgrade` | gp2 in-use |
| `EmptyAlb` | ALB | `load-balancer` | Zero registered targets |
| `NoRetentionLogGroup` | Log Group | `log-group` | No retention policy |
| `NoLifecycleBucket` | S3 Bucket | `s3-no-lifecycle` | No lifecycle config |
| `NeverInvokedLambda` | Lambda | `lambda-underutilized` | Zero invocations (7d) |
| `OverprovisionedTable` | DynamoDB | `dynamodb-overprovisioned` | RCU/WCU < 10% used |
| `OrphanedEni` | ENI | `eni-orphaned` | `Status: available` |
| `OrphanSnapshotCr` | EBS Snapshot | `ebs-snapshot` | Source volume deleted |
| VPC NAT Gateway (opt) | NAT | `nat-gateway` | Zero outbound traffic |

---

## Operational Flow

```
                    cdk deploy
                        │
                        ▼
        CloudFormation creates all resources
        (EC2 starts "running")
                        │
                        ▼
               scripts/post-deploy.sh
          Stops EC2 → stopped
                        │
                        ▼
              ⏳ Wait 5–10 minutes
        (CloudWatch registers zero-traffic metrics)
                        │
                        ▼
               scripts/validate.sh
          1. Runs: cloudrift analyze --all-services
                   --format json --min-age-days 0
          2. Parses JSON
          3. Verifies each expected kind is in findings
          4. Prints pass/fail
                        │
                        ▼
                  cdk destroy
          (full cleanup, no leftovers)
```

---

## Known Limitations

1. **`ebs-idle` and `ebs-gp2-upgrade`** require the `IdleInstance` to be running for at least 48h to generate zero-I/O CloudWatch metrics. May not appear immediately after deploy.

2. **`dynamodb-overprovisioned`** requires 7 days of low-utilization metrics in cloudrift's default. With `--min-age-days 0` the grace period is disabled, but the lookback window (168h default) may not have enough data for a freshly created table.

3. **`ec2-underutilized` and `rds-underutilized`** are not tested here because they require `--live-pricing` and an instance running for 14+ days with CPU < 5%.
