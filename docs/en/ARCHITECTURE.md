# Architecture — cloudrift-cdk-test

## Goal

Validate that cloudrift correctly detects wasted AWS resources on a real account (not localstack), with a reproducible and cost-controlled deployment.

---

## Design Decisions

### Construct-per-concern pattern

The monolithic stack is split into domain-specific L3 constructs:

| Construct | Responsibility |
|-----------|---------------|
| `Networking` | VPC, EIP, ENI, ALB, NAT Gateway, VPN, Transit Gateway |
| `Compute` | EC2 instances (stopped + idle) |
| `Storage` | EBS volumes, S3 buckets, orphan snapshot CR, EFS, FSx |
| `Serverless` | Lambda, DynamoDB, CloudWatch Log Groups |
| `Databases` | RDS (stopped), DocumentDB, Neptune, ElastiCache |
| `Analytics` | Redshift, OpenSearch |
| `Streaming` | Kinesis, MSK, Amazon MQ |
| `Workspaces` (opt-in) | Simple AD, WorkSpaces |

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

### Post-deploy script for stopped EC2 and RDS

CDK (CloudFormation) does not support creating EC2 or RDS instances in `stopped` state — they start `running`/`available`. The script `scripts/post-deploy.sh`:
1. Reads instance IDs from CloudFormation outputs
2. Stops EC2 with `aws ec2 stop-instances` + `wait`
3. Stops RDS with `aws rds stop-db-instance` + `wait`

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

### Custom Resource for the WorkSpaces AD user

Same gap-filling pattern as the orphan snapshot: CloudFormation has no native resource to create a user inside a Simple AD directory, but `AWS::WorkSpaces::Workspace` requires an existing `userName`. `lambda/create-ad-user` calls the DirectoryServiceData API (`CreateUser`/`DeleteUser`) as a Custom Resource so the WorkSpace has a valid user to attach to. Only deployed when `includeWorkspaces: true`.

### FSx for Lustre, not Windows File Server

FSx for Windows File Server requires an Active Directory (Managed Microsoft AD or self-managed) as a hard prerequisite — there's no standalone mode. FSx for Lustre (`SCRATCH_2` deployment type) needs no AD, so it's used instead to keep the always-on resources (everything except WorkSpaces) free of that dependency. Trade-off: Lustre's minimum practical size is 1200 GiB, larger than Windows' 32 GiB minimum would have been — see `docs/en/COSTS.md`.

### Minimal VPC (2 AZs, 0 NAT by default)

- 2 AZs is the minimum for ALB, and is reused as the subnet requirement for MSK, the Simple AD directory, and DB/cache subnet groups
- 0 NAT Gateways by default (high cost, ~$32/month)
- NAT can be enabled via context (`includeNatGateway: true`) to also test the `nat-gateway` scanner

### `includeWorkspaces`, opt-in and off by default

Every other new resource in this extension is always deployed — cost was explicitly ruled out as a constraint for a deploy→validate→destroy cycle of a few hours. WorkSpaces is the one exception, and for a different reason: a Simple AD directory takes 20-45 minutes to reach `ACTIVE` before the WorkSpace can even be created, which meaningfully lengthens the whole cycle compared to every other resource here (minutes, not tens of minutes). Enable with `includeWorkspaces: true` (context or `INCLUDE_WORKSPACES=true`) when you specifically need to validate `workspaces-idle`.

### Why `--min-age-days 0` and `--live-pricing` in validation

cloudrift has a default grace period of 7 days — newly created resources aren't flagged. For testing we use `--min-age-days 0` to disable it. Separately, 9 of the new scanners (ElastiCache, Redshift, OpenSearch, MSK, DocumentDB, Neptune, MQ, WorkSpaces, and `rds-underutilized`) are only registered when `--live-pricing` is passed — without it they don't run at all, regardless of resource state. This is a completely separate mechanism from the CloudWatch lookback window each idle scanner uses (48h by default): missing datapoints default to zero, so a freshly created idle resource is detected immediately once `--min-age-days 0` removes the age-based grace period — no need to actually wait out the lookback window in wall-clock time.

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
| `RdsInstance` | RDS db.t3.micro | `rds-instance` | `status: stopped` |
| `UnusedEfs` | EFS | `efs-unused` | Zero mount targets, or mounted with zero I/O |
| `ElastiCacheCluster` | cache.t4g.micro Redis | `elasticache-idle` | Zero connections (`--live-pricing`) |
| `RedshiftCluster` | dc2.large | `redshift-idle-cluster` | Zero connections (`--live-pricing`) |
| `OpenSearchDomain` | t3.small.search | `opensearch-idle-domain` | Zero search/index traffic (`--live-pricing`) |
| `MskCluster` | 2× kafka.t3.small, PROVISIONED | `msk-idle-cluster` | Zero broker traffic (`--live-pricing`) |
| `IdleFsx` | FSx for Lustre SCRATCH_2 | `fsx-idle-filesystem` | Zero I/O |
| `DocumentDbCluster` | db.t3.medium | `documentdb-idle-instance` | Zero connections (`--live-pricing`) |
| `NeptuneCluster` | db.t3.medium | `neptune-idle-instance` | Zero query traffic (`--live-pricing`) |
| `MqBroker` | mq.t3.micro, SINGLE_INSTANCE | `mq-idle-broker` | Zero network traffic (`--live-pricing`) |
| `IdleVpnConnection` | Site-to-Site VPN | `vpn-connection-idle` | Zero tunnel traffic |
| `IdleTransitGatewayAttachment` | TGW + VPC attachment | `transit-gateway-idle-attachment` | Zero traffic |
| `IdleStream` | Kinesis, 1 shard, PROVISIONED | `kinesis-provisioned-idle-stream` | Zero incoming activity |
| `IdleWorkspace` (opt-in) | WorkSpaces, ALWAYS_ON | `workspaces-idle` | Never connected (`--live-pricing`) |
| VPC NAT Gateway (opt) | NAT | `nat-gateway` | Zero outbound traffic |

---

## Operational Flow

```
                    cdk deploy
                        │
                        ▼
        CloudFormation creates all resources
        (EC2/RDS start "running"/"available")
                        │
                        ▼
               scripts/post-deploy.sh
          Stops EC2 → stopped
          Stops RDS → stopped
                        │
                        ▼
              ⏳ Wait 5–10 minutes
        (CloudWatch registers zero-traffic metrics)
                        │
                        ▼
               scripts/validate.sh
          1. Runs: cloudrift analyze --all-services
                   --format json --min-age-days 0 --live-pricing
          2. Parses JSON
          3. Verifies each expected kind is in findings
          4. Prints pass/fail
                        │
                        ▼
                  cdk destroy
          (full cleanup, no leftovers)
```

Note: `cdk deploy` and `cdk destroy` both take noticeably longer than before this extension — MSK, DocumentDB, Neptune, Redshift, and OpenSearch each take 10-20 minutes to provision/tear down (CloudFormation waits for each to reach a stable state). Expect the full cycle to run 30-60 minutes even without `includeWorkspaces`.

---

## Known Limitations

1. **`ebs-idle` and `ebs-gp2-upgrade`** require the `IdleInstance` to be running for at least 48h to generate zero-I/O CloudWatch metrics. May not appear immediately after deploy.

2. **`dynamodb-overprovisioned`** requires 7 days of low-utilization metrics in cloudrift's default. With `--min-age-days 0` the grace period is disabled, but the lookback window (168h default) may not have enough data for a freshly created table.

3. **`ec2-underutilized` and `rds-underutilized`** are not tested here. Both use MAX(CPU) over a *fixed* 168h lookback window (`utilizationWindowHours`), not a rolling average. A freshly created EC2/RDS instance has a genuine CPU spike during boot/initialization, and that spike stays inside the 168h window — and therefore keeps failing the `max CPU < 5%` condition — for a full 7 days after creation, regardless of how long the instance sits idle afterward. There's no way to trigger these two scanners within a short deploy→validate→destroy cycle.

4. **`mq-idle-broker`**: the Amazon MQ broker needs to reach `RUNNING` state before it reports metrics — this can take several minutes after `cdk deploy` finishes, longer than most of the other scanners here.

5. **WorkSpaces bundle ID** (`lib/constructs/workspaces.ts`): `VALUE_BUNDLE_ID_BY_REGION` hardcodes a public "Value" bundle ID per region. AWS changes these over time — if `cdk deploy` fails with an invalid-bundle error, look up the current ID for your region and update the map.

6. **WorkSpaces AD user creation** (`lambda/create-ad-user/index.js`): written from general knowledge of the DirectoryServiceData API (`CreateUser`/`DeleteUser`), not verified against a live deploy. Check the Lambda's CloudWatch logs on first use with `includeWorkspaces: true` and adjust the API call shape if it fails.

7. **FSx throughput-capacity pricing**: the cost estimate for `IdleFsx` (FSx for Lustre) in `docs/en/COSTS.md` is a best-effort estimate, not independently verified against current AWS pricing — check your first bill before treating it as accurate for planning.
