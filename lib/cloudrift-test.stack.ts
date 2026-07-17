import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { IStackConfig } from './config';
import { Networking } from './constructs/networking';
import { Compute } from './constructs/compute';
import { Storage } from './constructs/storage';
import { Serverless } from './constructs/serverless';
import { ServerlessOrphans } from './constructs/serverless-orphans';
import { Databases } from './constructs/databases';
import { Analytics } from './constructs/analytics';
import { Streaming } from './constructs/streaming';
import { Workspaces } from './constructs/workspaces';
import { SageMaker } from './constructs/sagemaker';
import { Eks } from './constructs/eks';
import { Environments } from './constructs/environments';

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
 *
 * Coverage: all 38 cloudrift scanner kinds are testable by this stack
 * (some gated behind opt-in flags for cost/time reasons).
 */
export class CloudriftTestStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CloudriftTestStackProps) {
    super(scope, id, props);

    const { config } = props;

    // ─── Networking: VPC, EIP, ENI, ALB, NAT Gateway, VPN, Transit Gateway
    const networking = new Networking(this, 'Networking', { config });

    // ─── Compute: EC2 instances (stopped + idle + optionally underutilized)
    new Compute(this, 'Compute', {
      vpc: networking.vpc,
      stoppedInstanceSg: networking.stoppedInstanceSg,
      includeUnderutilized: config.includeTimeDependentResources,
    });

    // ─── Storage: EBS volumes, S3 buckets, orphan snapshot, EFS, FSx
    new Storage(this, 'Storage', { vpc: networking.vpc });

    // ─── Serverless: Lambda, DynamoDB, CloudWatch Log Groups
    new Serverless(this, 'Serverless');

    // ─── Serverless Orphans: orphaned Lambda log group (always), SQS DLQ (time-dependent),
    //     Aurora Serverless v2 (time-dependent).
    new ServerlessOrphans(this, 'ServerlessOrphans', {
      vpc: networking.vpc,
      includeAuroraServerless: config.includeAuroraServerless,
      includeSqsDlq: config.includeTimeDependentResources,
    });

    // ─── Databases: RDS (stopped + optionally underutilized), DocumentDB, Neptune, ElastiCache
    const databases = new Databases(this, 'Databases', {
      vpc: networking.vpc,
      includeUnderutilized: config.includeTimeDependentResources,
    });

    // ─── Analytics: Redshift, OpenSearch
    const analytics = new Analytics(this, 'Analytics', { vpc: networking.vpc });

    // ─── Streaming: Kinesis, MSK, Amazon MQ
    //     MSK takes 20+ min to create and CANNOT be deleted while in CREATING
    //     state. If it starts in parallel and something else fails, the
    //     rollback deadlocks for 20 min. By depending on Analytics and
    //     Databases (the most likely to fail), MSK only starts once those
    //     are confirmed — so a failure there triggers a clean, fast rollback.
    const streaming = new Streaming(this, 'Streaming', { vpc: networking.vpc });
    streaming.node.addDependency(analytics);
    streaming.node.addDependency(databases);

    // ─── Environments (time-dependent, 7d): ghost dev/PR environment
    if (config.includeTimeDependentResources) {
      new Environments(this, 'Environments', { vpc: networking.vpc });
    }

    // ─── Workspaces (opt-in): Simple AD + AlwaysOn WorkSpace
    if (config.includeWorkspaces) {
      new Workspaces(this, 'Workspaces', { vpc: networking.vpc });
    }

    // ─── SageMaker (opt-in): Notebook, Endpoint, orphaned Model
    if (config.includeSageMaker) {
      new SageMaker(this, 'SageMaker', { vpc: networking.vpc });
    }

    // ─── EKS (opt-in): cluster with overprovisioned node group + orphan PVC volume
    if (config.includeEks) {
      new Eks(this, 'Eks', { vpc: networking.vpc });
    }
  }
}
