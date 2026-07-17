# cloudrift-cdk-test

AWS CDK v2 (TypeScript) project that deploys intentionally **wasted** AWS resources to validate [cloudrift](https://github.com/elleVas/cloudrift) detection capabilities.

> **This is not a production project.** It exists solely to verify that cloudrift correctly detects every type of waste on a real AWS account.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [AWS Configuration](#aws-configuration)
- [Quick Start](#quick-start)
- [Deployed Resources](#deployed-resources)
- [NAT Gateway (optional)](#nat-gateway-optional)
- [WorkSpaces (optional)](#workspaces-optional)
- [Architecture](#architecture)
- [cloudrift Configuration](#cloudrift-configuration)
- [Estimated Costs](#estimated-costs)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)
- [License](#license)

---

## Prerequisites

- **Node.js 18+**
- **AWS CLI v2** configured with credentials for a **sandbox** account (never production)
- **AWS CDK CLI**: `npm install -g aws-cdk` (or use `npx cdk` — already in devDependencies)
- **cloudrift** cloned and built (see [cloudrift Configuration](#cloudrift-configuration))
- **CDK bootstrapped account**: `npx cdk bootstrap aws://ACCOUNT_ID/REGION`

---

## AWS Configuration

The project uses the active AWS credentials in your shell — no accounts are hardcoded. CDK reads account and region from the current profile.

### Choosing an account

```bash
# Option A — Named profile (recommended)
export AWS_PROFILE=sandbox

# Option B — Default profile
# If already configured with `aws configure`, nothing else needed.

# Option C — Explicit environment variables
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=wJalr...
export AWS_DEFAULT_REGION=us-east-1
```

### Verify credentials

```bash
aws sts get-caller-identity
# Should return the account ID without errors
```

### Region

The stack deploys to whatever region your AWS CLI profile is configured for. All scripts auto-detect the region from `AWS_REGION` → `AWS_DEFAULT_REGION` → `aws configure get region`, in that order.

```bash
# Check which region your profile uses
aws configure get region

# Override if needed
export AWS_DEFAULT_REGION=eu-central-1
```

> **Important**: all commands (`deploy`, `post-deploy`, `validate`, `cleanup`) use the same auto-detection logic. You do NOT need to prefix commands with `AWS_REGION=...` as long as your profile is set correctly.

### Bootstrap CDK (one-time per account/region)

```bash
npx cdk bootstrap aws://ACCOUNT_ID/REGION
# Example: npx cdk bootstrap aws://123456789012/eu-central-1
```

---

## Quick Start

```bash
# 1. Install dependencies
npm install

# 2. Deploy resources (~35 min — MSK, Neptune, DocumentDB, Redshift, OpenSearch are slow)
npm run deploy

# 3. Stop EC2 + RDS instances (CDK cannot create them in "stopped" state)
npm run post-deploy

# 4. Wait ~5 minutes for CloudWatch metrics, then validate
npm run validate

# 5. IMPORTANT: destroy everything to avoid accumulating costs (~20 min)
npm run cleanup
```

### Validation commands

| Command | Description |
|---------|-------------|
| `npm run validate` | Automated script: runs cloudrift, verifies each expected kind is detected, prints pass/fail |
| `npm run validate:cli` | Runs cloudrift directly with terminal output (readable tables) |
| `npm run validate:pdf` | Like `validate:cli` but also generates a PDF report |

### One-liner (deploy → stop → wait → validate)

```bash
npm run test:full
```

---

## Deployed Resources

| Resource | Waste/Optimization Type | cloudrift Scanner | Qty |
|----------|------------------------|-------------------|-----|
| EBS Volume gp2 8GB (unattached) | waste | `ebs-volume` | 1 |
| EBS Volume gp3 8GB (unattached) | waste | `ebs-volume` | 1 |
| Elastic IP (unassociated) | waste | `elastic-ip` | 1 |
| EC2 t3.micro (stopped) | waste | `ec2-instance` | 1 |
| EC2 t3.micro running + gp2 (zero I/O) | waste + optimization | `ebs-idle` + `ebs-gp2-upgrade` | 1 |
| ALB with no targets | waste | `load-balancer` | 1 |
| CloudWatch Log Group (no retention) | waste | `log-group` | 5 |
| S3 Bucket (no lifecycle) | optimization | `s3-no-lifecycle` | 5 |
| Lambda (never invoked) | optimization | `lambda-underutilized` | 1 |
| DynamoDB table PROVISIONED (zero traffic) | optimization | `dynamodb-overprovisioned` | 1 |
| Standalone ENI | waste | `eni-orphaned` | 1 |
| EBS Snapshot (source volume deleted) | waste | `ebs-snapshot` | 1 |
| RDS db.t3.micro (stopped) | waste | `rds-instance` | 1 |
| EFS (zero I/O) | waste | `efs-unused` | 1 |
| ElastiCache cache.t4g.micro (zero connections) | waste | `elasticache-idle` | 1 |
| Redshift ra3.xlplus (zero connections) | waste | `redshift-idle-cluster` | 1 |
| OpenSearch t3.small.search (zero traffic) | waste | `opensearch-idle-domain` | 1 |
| MSK 2× kafka.t3.small (zero broker traffic) | waste | `msk-idle-cluster` | 1 |
| FSx for Lustre 1200GiB (zero I/O) | waste | `fsx-idle-filesystem` | 1 |
| DocumentDB db.t3.medium (zero connections) | waste | `documentdb-idle-instance` | 1 |
| Neptune db.t3.medium (zero query traffic) | waste | `neptune-idle-instance` | 1 |
| Amazon MQ mq.t3.micro (zero traffic) | waste | `mq-idle-broker` | 1 |
| VPN Site-to-Site connection (zero traffic) | waste | `vpn-connection-idle` | 1 |
| Transit Gateway + VPC attachment (zero traffic) | waste | `transit-gateway-idle-attachment` | 1 |
| Kinesis stream, 1 shard (zero activity) | waste | `kinesis-provisioned-idle-stream` | 1 |
| NAT Gateway (optional, zero traffic) | waste | `nat-gateway` | 0–1 |
| WorkSpaces AlwaysOn (optional, never connected) | waste | `workspaces-idle` | 0–1 |

`ElastiCache`, `Redshift`, `OpenSearch`, `MSK`, `DocumentDB`, `Neptune`, `MQ`, and `WorkSpaces` scanners require `--live-pricing` — `npm run validate`/`validate:cli`/`validate:pdf` already pass it.

---

## NAT Gateway (optional)

The NAT Gateway costs ~$1.08/day and is disabled by default. To include it:

```bash
# Via environment variable
INCLUDE_NAT_GATEWAY=true npm run deploy

# Via CDK context
npx cdk deploy -c includeNatGateway=true --require-approval never
```

---

## WorkSpaces (optional)

Deploys a Simple AD directory + one AlwaysOn WorkSpace to validate `workspaces-idle`. Off by default because Simple AD takes 20-45min to reach `ACTIVE`, on top of the WorkSpace's own provisioning time — this roughly doubles the deploy cycle compared to everything else in this stack.

```bash
INCLUDE_WORKSPACES=true npm run deploy
# or
npx cdk deploy -c includeWorkspaces=true --require-approval never
```

---

## Architecture

The project follows the **Construct-per-concern** pattern — each domain area is encapsulated in its own L3 construct:

```
cloudrift-cdk-test/
├── bin/
│   └── app.ts                        # CDK app entry point
├── lib/
│   ├── config.ts                     # IStackConfig interface (feature toggles)
│   ├── cloudrift-test.stack.ts       # Main stack — composes constructs
│   └── constructs/
│       ├── networking.ts             # VPC, EIP, ENI, ALB, NAT, VPN, Transit Gateway
│       ├── compute.ts                # EC2 instances (stopped + idle)
│       ├── storage.ts                # EBS volumes, S3, orphan snapshot CR, EFS, FSx
│       ├── serverless.ts             # Lambda, DynamoDB, Log Groups
│       ├── databases.ts              # RDS (stopped), DocumentDB, Neptune, ElastiCache
│       ├── analytics.ts              # Redshift, OpenSearch
│       ├── streaming.ts              # Kinesis, MSK, Amazon MQ
│       └── workspaces.ts             # Simple AD + WorkSpaces (opt-in)
├── lambda/
│   ├── orphan-snapshot/
│   │   └── index.js                  # Custom Resource handler
│   └── create-ad-user/
│       └── index.js                  # Custom Resource handler (WorkSpaces AD user)
├── scripts/
│   ├── post-deploy.sh                # Stops EC2 + RDS after deploy
│   ├── validate.sh                   # Runs cloudrift & checks findings
│   └── concurrency-test.sh
├── docs/
│   ├── en/                           # English documentation
│   │   ├── ARCHITECTURE.md
│   │   ├── COSTS.md
│   │   └── GUIDE.md
│   └── it/                           # Italian documentation
│       ├── ARCHITECTURE.md
│       ├── COSTS.md
│       └── GUIDE.md
├── cdk.json
├── package.json
└── tsconfig.json
```

### Why this pattern?

- **Separation of concerns**: each construct owns its resources and IAM policies
- **Testability**: constructs can be instantiated independently in unit tests
- **Readability**: the main stack reads like a high-level architecture diagram
- **Extensibility**: adding a new concern (e.g., databases) means adding one file + one line in the stack

---

## cloudrift Configuration

The `validate.sh` script looks for cloudrift at `../../cloudrift` (relative to this project root). If your clone is elsewhere:

```bash
CLOUDRIFT_PATH=/path/to/cloudrift npm run validate
```

Make sure it's built:

```bash
cd /path/to/cloudrift
pnpm install
pnpm nx build cli
```

---

## Estimated Costs

These are monthly-equivalent figures, useful for comparing resources — not what a real deploy→validate→destroy cycle costs (~$2-4 for a single run, see the full breakdown).

| Scenario | Cost/day | Cost/week |
|----------|----------|-----------|
| Full stack (all vertical scanners, no WorkSpaces) | ~$24 | ~$168 |
| Full stack + NAT Gateway | ~$25 | ~$175 |
| Full stack + WorkSpaces | ~$32 | ~$224 |

A single deploy→validate→destroy cycle takes ~1 hour and costs **~$2-4** depending on options.

Full breakdown: [docs/en/COSTS.md](docs/en/COSTS.md)

> **Destroy resources immediately after testing.** `npm run cleanup` removes everything.

---

## Security

- **Use ONLY a sandbox/dev account** — never production
- Deployed resources are intentionally wasteful (SGs are locked down, no public data access, but the posture is not production-grade)
- Resources are NOT tagged with `cloudrift:ignore` (otherwise they wouldn't be detected)
- `RemovalPolicy.DESTROY` on everything for easy cleanup
- **Note on `unsafeUnwrap()`**: `workspaces.ts` and `streaming.ts` use `secretValue.unsafeUnwrap()` to pass secrets to L1 CFN resources that don't support dynamic references. This means the secret value appears in plaintext in the synthesized CloudFormation template. Acceptable for a disposable test stack in a sandbox account — do NOT copy this pattern into production code.

---

## Troubleshooting

### cloudrift doesn't find resources

1. Did you run `npm run post-deploy`? (EC2 and RDS must be stopped)
2. Has at least 5-10 minutes passed? (CloudWatch needs time to register zero-traffic)
3. Are you using `--min-age-days 0`? (the validation script does this, but remember it when running manually)
4. Are you using `--live-pricing`? Required for ElastiCache, Redshift, OpenSearch, MSK, DocumentDB, Neptune, MQ, and WorkSpaces — without it those scanners never run (`npm run validate*` already pass it)
5. `ebs-idle` needs 48h of zero-I/O metrics — won't pass on a deploy→validate→destroy cycle of < 48h (see Known Limitations)

### cdk deploy fails

1. Did you bootstrap? `npx cdk bootstrap aws://ACCOUNT/REGION`
2. Do credentials have sufficient permissions? You need broad permissions — see [docs/en/GUIDE.md](docs/en/GUIDE.md) for the full IAM policy
3. WorkSpaces bundle ID invalid? See "Known Limitations" in [docs/en/ARCHITECTURE.md](docs/en/ARCHITECTURE.md)
4. **Deploy ordering**: MSK only starts creating after all Analytics and Databases resources are confirmed. If Redshift or OpenSearch fail, the rollback is fast (no stuck MSK in CREATING state)

---

## Documentation

Detailed documentation is available in both English and Italian:

| Document | English | Italiano |
|----------|---------|----------|
| Architecture & design decisions | [docs/en/ARCHITECTURE.md](docs/en/ARCHITECTURE.md) | [docs/it/ARCHITECTURE.md](docs/it/ARCHITECTURE.md) |
| Cost breakdown | [docs/en/COSTS.md](docs/en/COSTS.md) | [docs/it/COSTS.md](docs/it/COSTS.md) |
| IAM setup guide | [docs/en/GUIDE.md](docs/en/GUIDE.md) | [docs/it/GUIDE.md](docs/it/GUIDE.md) |

---

## License

Same as the cloudrift project — Apache License 2.0.
