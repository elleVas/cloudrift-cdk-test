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
- **AWS CDK CLI**: `npm install -g aws-cdk`
- **cloudrift** cloned and built (see [cloudrift Configuration](#cloudrift-configuration))
- **CDK bootstrapped account**: `cdk bootstrap aws://ACCOUNT_ID/REGION`

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

The stack deploys to `us-east-1` by default. To change:

```bash
export CDK_DEFAULT_REGION=eu-west-1
# or
export AWS_DEFAULT_REGION=eu-west-1
```

### Bootstrap CDK (one-time per account/region)

```bash
cdk bootstrap aws://ACCOUNT_ID/REGION
# Example: cdk bootstrap aws://123456789012/us-east-1
```

---

## Quick Start

```bash
# 1. Install dependencies
npm install

# 2. Deploy resources
npm run deploy

# 3. Stop EC2 instance (CDK cannot create them in "stopped" state)
npm run post-deploy

# 4. Wait ~5 minutes for CloudWatch metrics, then validate
npm run validate

# 5. IMPORTANT: destroy everything to avoid accumulating costs
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
| NAT Gateway (optional, zero traffic) | waste | `nat-gateway` | 0–1 |

---

## NAT Gateway (optional)

The NAT Gateway costs ~$1.08/day and is disabled by default. To include it:

```bash
# Via environment variable
INCLUDE_NAT_GATEWAY=true npm run deploy

# Via CDK context
cdk deploy -c includeNatGateway=true
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
│       ├── networking.ts             # VPC, EIP, ENI, ALB
│       ├── compute.ts                # EC2 instances (stopped + idle)
│       ├── storage.ts                # EBS volumes, S3, orphan snapshot CR
│       └── serverless.ts             # Lambda, DynamoDB, Log Groups
├── lambda/
│   └── orphan-snapshot/
│       └── index.js                  # Custom Resource handler
├── scripts/
│   ├── post-deploy.sh                # Stops EC2 after deploy
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

| Scenario | Cost/day | Cost/week |
|----------|----------|-----------|
| Without NAT Gateway | ~$1.20 | ~$8.40 |
| With NAT Gateway | ~$2.30 | ~$16.10 |

Full breakdown: [docs/en/COSTS.md](docs/en/COSTS.md)

> **Destroy resources immediately after testing.** `npm run cleanup` removes everything.

---

## Security

- **Use ONLY a sandbox/dev account** — never production
- Deployed resources are intentionally wasteful (SGs are locked down, no public data access, but the posture is not production-grade)
- Resources are NOT tagged with `cloudrift:ignore` (otherwise they wouldn't be detected)
- `RemovalPolicy.DESTROY` on everything for easy cleanup

---

## Troubleshooting

### cloudrift doesn't find resources

1. Did you run `npm run post-deploy`? (EC2 must be stopped)
2. Has at least 5 minutes passed? (CloudWatch needs time to register zero-traffic)
3. Are you using `--min-age-days 0`? (the validation script does this, but remember it when running manually)

### cdk deploy fails

1. Did you bootstrap? `cdk bootstrap aws://ACCOUNT/REGION`
2. Do credentials have sufficient permissions? You need broad permissions (EC2, ELB, S3, Lambda, DynamoDB, CloudWatch, IAM, etc.)

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
