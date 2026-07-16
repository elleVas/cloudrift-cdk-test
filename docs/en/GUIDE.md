# Guide: Create a Temporary IAM User for cloudrift-cdk-test

This guide explains how to create an IAM user with the permissions needed to deploy the CDK stack and run cloudrift. The user should be deleted after testing.

---

## Prerequisites

- Access to the AWS console with IAM management permissions
- A sandbox/dev account (never production)

---

## Step 1 — Create the policy

1. Go to **IAM → Policies → Create policy**
2. Select the **JSON** tab
3. Paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudriftCDKTestFullAccess",
      "Effect": "Allow",
      "Action": [
        "cloudformation:*",
        "ec2:*",
        "elasticloadbalancing:*",
        "s3:*",
        "logs:*",
        "lambda:*",
        "dynamodb:*",
        "iam:*",
        "ssm:*",
        "ecr:*",
        "sts:GetCallerIdentity",
        "cloudwatch:GetMetricStatistics",
        "pricing:GetProducts",
        "rds:*",
        "elasticache:*",
        "redshift:*",
        "es:*",
        "kafka:*",
        "fsx:*",
        "elasticfilesystem:*",
        "mq:*",
        "kinesis:*",
        "secretsmanager:*",
        "workspaces:*",
        "ds:*",
        "ds-data:*"
      ],
      "Resource": "*"
    }
  ]
}
```

> `rds:*` covers RDS, DocumentDB, and Neptune (all three use the RDS API namespace). `workspaces:*`/`ds:*`/`ds-data:*` are only needed if you deploy with `includeWorkspaces: true`.

4. Click **Next**
5. Name: `CloudriftTestFullAccess`
6. Click **Create policy**

> **Note**: `Resource: *` is required because AWS Describe/List APIs and CDK bootstrap need global access. Security is ensured by using a dedicated sandbox account.

---

## Step 2 — Create the user

1. Go to **IAM → Users → Create user**
2. Name: `cloudrift-test` (or your preference)
3. **Do not** check "Provide user access to the AWS Management Console" (only programmatic access needed)
4. Click **Next**
5. Select **Attach policies directly**
6. Search for `CloudriftTestFullAccess` and select it
7. Click **Next → Create user**

---

## Step 3 — Create Access Keys

1. Go to **IAM → Users → `cloudrift-test`**
2. **Security credentials** tab
3. "Access keys" section → **Create access key**
4. Select **Command Line Interface (CLI)**
5. Confirm and click **Create access key**
6. **Copy immediately** the Access Key ID and Secret Access Key (the secret won't be visible again)

---

## Step 4 — Configure your terminal

```bash
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=wJalr...
export AWS_DEFAULT_REGION=us-east-1
```

Verify:

```bash
aws sts get-caller-identity
# Should return the account ID without errors
```

---

## Step 5 — Bootstrap CDK (one-time)

```bash
npx cdk bootstrap
```

If it fails with permission errors and you just created the policy, verify you included `ssm:*` and `ecr:*` (required by bootstrap).

If bootstrap had previously failed:

```bash
aws cloudformation delete-stack --stack-name CDKToolkit
aws cloudformation wait stack-delete-complete --stack-name CDKToolkit
npx cdk bootstrap
```

---

## Step 6 — Deploy and test

```bash
npm run deploy
# Deploy takes 30-60min: MSK, DocumentDB, Neptune, Redshift, and
# OpenSearch each take 10-20min to provision.
npm run post-deploy
# Wait 5-10 minutes
npm run validate:cli   # terminal output
npm run validate:pdf   # terminal output + PDF
npm run validate       # automated pass/fail check
```

Optional: `INCLUDE_WORKSPACES=true npm run deploy` also deploys a Simple AD + WorkSpace (`workspaces-idle` scanner) — adds 20-45min to the deploy for Simple AD to reach `ACTIVE`, on top of the workspace itself.

---

## Step 7 — Cleanup

```bash
# Destroy all AWS resources
npm run cleanup
```

---

## Step 8 — Delete the user

After testing, from the AWS console:

1. **IAM → Users → `cloudrift-test` → Delete**
2. **IAM → Policies → `CloudriftTestFullAccess` → Delete**

---

## Alternative: AdministratorAccess

If you don't want to create a custom policy, you can attach the `AdministratorAccess` managed policy directly:

1. IAM → Users → `cloudrift-test` → Permissions → Add permissions
2. Attach policies directly → search `AdministratorAccess` → select

Works for everything (bootstrap, deploy, cloudrift). Remove/delete as soon as testing is done.

---

## Alternative: IAM Identity Center (SSO)

If you use AWS Organizations with IAM Identity Center:

1. Create a **Permission Set** with an inline policy (same JSON above)
2. Assign it to your user on the target account
3. From the SSO portal (`https://d-xxxxxxxx.awsapps.com/start`) get temporary credentials
4. Or configure an SSO profile:

```bash
aws configure sso
# prompts: SSO start URL, region, account, permission set
export AWS_PROFILE=your-chosen-name
aws sso login --profile your-chosen-name
```

---

## Command Summary

| Command | What it does |
|---------|--------------|
| `npm run deploy` | Deploys the stack |
| `npm run post-deploy` | Stops EC2 and RDS instances |
| `npm run validate` | Automated check (pass/fail per scanner) |
| `npm run validate:cli` | cloudrift with terminal table output |
| `npm run validate:pdf` | cloudrift with tables + PDF report |
| `npm run cleanup` | Destroys all AWS resources |
| `npm run test:full` | One-liner: deploy → stop → wait 5min → validate |
