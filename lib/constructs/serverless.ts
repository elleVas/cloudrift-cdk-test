import * as cdk from 'aws-cdk-lib';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import { Construct } from 'constructs';

/**
 * Serverless construct: Lambda (never invoked), DynamoDB (overprovisioned),
 * CloudWatch Log Groups (no retention).
 */
export class Serverless extends Construct {
  constructor(scope: Construct, id: string) {
    super(scope, id);

    // ─── CloudWatch Log Groups with NO retention — waste: log-group
    for (let i = 0; i < 5; i++) {
      new logs.LogGroup(this, `NoRetentionLogGroup${i}`, {
        logGroupName: `/cloudrift-test/no-retention-${i}`,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
      });
    }

    // ─── Lambda function never invoked — optimization: lambda-underutilized
    new lambda.Function(this, 'NeverInvokedLambda', {
      functionName: 'cloudrift-test-never-invoked',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromInline(`
        exports.handler = async () => {
          return { statusCode: 200, body: 'This function is never called' };
        };
      `),
      timeout: cdk.Duration.seconds(3),
      memorySize: 128,
    });

    // ─── DynamoDB table PROVISIONED with unused capacity
    //     optimization: dynamodb-overprovisioned
    new dynamodb.Table(this, 'OverprovisionedTable', {
      tableName: 'cloudrift-test-overprovisioned',
      partitionKey: { name: 'pk', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PROVISIONED,
      readCapacity: 5,
      writeCapacity: 5,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
  }
}
