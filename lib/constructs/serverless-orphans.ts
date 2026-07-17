import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as rds from 'aws-cdk-lib/aws-rds';
import { Construct } from 'constructs';

export interface ServerlessOrphansProps {
  readonly vpc: ec2.Vpc;
  /** Deploy Aurora Serverless v2 (requires 168h/7d of metrics). Default: false. */
  readonly includeAuroraServerless?: boolean;
  /** Deploy SQS DLQ (requires 14d of message aging). Default: false. */
  readonly includeSqsDlq?: boolean;
}

/**
 * Serverless Orphans construct: resources that represent "hygiene waste" —
 * abandoned DLQs, orphaned Lambda log groups, and overprovisioned Aurora
 * Serverless v2.
 *
 * Scanners covered:
 *   - sqs-dlq-abandoned: DLQ with old unconsumed messages (time-dependent, 14d)
 *   - lambda-loggroup-orphaned: /aws/lambda/* log group whose function was deleted (instant)
 *   - aurora-serverless-overprovisioned: Aurora Serverless v2 with Min ACU far above peak (time-dependent, 7d)
 */
export class ServerlessOrphans extends Construct {
  constructor(scope: Construct, id: string, props: ServerlessOrphansProps) {
    super(scope, id);

    const { vpc } = props;

    // ─── SQS Dead Letter Queue — abandoned (messages sitting unconsumed)
    //     waste: sqs-dlq-abandoned
    //     TIME-DEPENDENT: messages must age 14 days to trigger detection.
    if (props.includeSqsDlq) {
      const dlq = new sqs.Queue(this, 'AbandonedDlq', {
        queueName: 'cloudrift-test-abandoned-dlq',
        retentionPeriod: cdk.Duration.days(14),
        removalPolicy: cdk.RemovalPolicy.DESTROY,
      });

      // Source queue that routes failures to the DLQ
      const sourceQueue = new sqs.Queue(this, 'SourceQueue', {
        queueName: 'cloudrift-test-source-queue',
        deadLetterQueue: {
          queue: dlq,
          maxReceiveCount: 1,
        },
        removalPolicy: cdk.RemovalPolicy.DESTROY,
      });

      // Set RedriveAllowPolicy on the DLQ to explicitly mark it as a redrive target
      const cfnDlq = dlq.node.defaultChild as sqs.CfnQueue;
      cfnDlq.addPropertyOverride('RedriveAllowPolicy', JSON.stringify({
        redrivePermission: 'byQueue',
        sourceQueueArns: [sourceQueue.queueArn],
      }));
    }

    // ─── Lambda Log Group — orphaned (function no longer exists)
    //     waste: lambda-loggroup-orphaned
    //     INSTANT: just needs the function to not exist — no time dependency.
    new logs.LogGroup(this, 'OrphanedLambdaLogGroup', {
      logGroupName: '/aws/lambda/cloudrift-test-deleted-function',
      retention: logs.RetentionDays.ONE_WEEK, // Retention is set to avoid triggering log-group scanner
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ─── Aurora Serverless v2 — overprovisioned Min ACU
    //     optimization: aurora-serverless-overprovisioned
    //     TIME-DEPENDENT: requires 168h (7 days) of CloudWatch metrics.
    if (props.includeAuroraServerless) {
      const auroraSg = new ec2.SecurityGroup(this, 'AuroraServerlessSg', {
        vpc,
        description: 'SG for the idle Aurora Serverless v2 cluster',
        allowAllOutbound: false,
      });

      new rds.DatabaseCluster(this, 'AuroraServerlessCluster', {
        engine: rds.DatabaseClusterEngine.auroraPostgres({
          version: rds.AuroraPostgresEngineVersion.VER_16_4,
        }),
        vpc,
        vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
        securityGroups: [auroraSg],
        serverlessV2MinCapacity: 2, // Intentionally high — peak will be ~0.5 ACU
        serverlessV2MaxCapacity: 4,
        writer: rds.ClusterInstance.serverlessV2('Writer', {}),
        credentials: rds.Credentials.fromGeneratedSecret('postgres'),
        removalPolicy: cdk.RemovalPolicy.DESTROY,
        deletionProtection: false,
      });
    }
  }
}
