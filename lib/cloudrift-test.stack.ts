import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { IStackConfig } from './config';
import { Networking } from './constructs/networking';
import { Compute } from './constructs/compute';
import { Storage } from './constructs/storage';
import { Serverless } from './constructs/serverless';
import { Databases } from './constructs/databases';
import { Analytics } from './constructs/analytics';
import { Streaming } from './constructs/streaming';
import { Workspaces } from './constructs/workspaces';

export interface CloudriftTestStackProps extends cdk.StackProps {
  readonly config: IStackConfig;
}

/**
 * Main stack — composes domain-specific constructs to deploy intentionally
 * wasted AWS resources for validating cloudrift detection.
 *
 * Architecture: Construct-per-concern pattern.
 * Each concern (networking, compute, storage, serverless) is encapsulated
 * in its own L3 construct under lib/constructs/.
 */
export class CloudriftTestStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CloudriftTestStackProps) {
    super(scope, id, props);

    const { config } = props;

    // ─── Networking: VPC, EIP, ENI, ALB, (optional) NAT Gateway
    const networking = new Networking(this, 'Networking', { config });

    // ─── Compute: EC2 instances (stopped + idle)
    new Compute(this, 'Compute', {
      vpc: networking.vpc,
      stoppedInstanceSg: networking.stoppedInstanceSg,
    });

    // ─── Storage: EBS volumes, S3 buckets, orphan snapshot
    new Storage(this, 'Storage', { vpc: networking.vpc });

    // ─── Serverless: Lambda, DynamoDB, CloudWatch Log Groups
    new Serverless(this, 'Serverless');

    // ─── Databases: RDS (stopped), DocumentDB, Neptune, ElastiCache
    new Databases(this, 'Databases', { vpc: networking.vpc });

    // ─── Analytics: Redshift, OpenSearch
    new Analytics(this, 'Analytics', { vpc: networking.vpc });

    // ─── Streaming: Kinesis, MSK, Amazon MQ
    new Streaming(this, 'Streaming', { vpc: networking.vpc });

    // ─── Workspaces (opt-in): Simple AD + AlwaysOn WorkSpace
    if (config.includeWorkspaces) {
      new Workspaces(this, 'Workspaces', { vpc: networking.vpc });
    }
  }
}
