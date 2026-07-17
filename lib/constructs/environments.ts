import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { Construct } from 'constructs';

export interface EnvironmentsProps {
  readonly vpc: ec2.Vpc;
}

/**
 * Environments construct: a group of resources tagged with the same
 * `Environment` value, all inactive — simulates a forgotten dev/PR
 * environment that was never torn down.
 *
 * Scanner covered:
 *   - environment-ghost: all resources in the group are inactive for > 7 days
 *
 * The scanner detects ghost environments by:
 *   1. Grouping resources by Environment/env/branch tag value
 *   2. Checking if ALL resources in the group are inactive:
 *      - EC2: stopped
 *      - RDS: stopped
 *      - Lambda: zero invocations over 7 days
 *      - ALB: zero registered targets
 *   3. If all are inactive for > 7 days → waste
 *
 * We create a stopped EC2 instance + a never-invoked Lambda, both tagged
 * with `Environment=pr-42-stale`. The post-deploy script stops the EC2.
 * After 7+ days both will appear inactive → ghost environment detected.
 *
 * For immediate testing with --min-age-days 0, the scanner still needs
 * the inactivity window (7 days by default). This scanner is inherently
 * time-dependent. However, the EC2 being stopped and Lambda having zero
 * invocations since deploy satisfies the conditions once enough time passes.
 */
export class Environments extends Construct {
  public readonly ghostInstance: ec2.Instance;

  constructor(scope: Construct, id: string, props: EnvironmentsProps) {
    super(scope, id);

    const { vpc } = props;
    const envTagValue = 'pr-42-stale';

    // ─── EC2 instance tagged as part of a ghost environment (will be stopped)
    const ghostSg = new ec2.SecurityGroup(this, 'GhostEnvSg', {
      vpc,
      description: 'SG for the ghost environment EC2 instance',
      allowAllOutbound: false,
    });

    this.ghostInstance = new ec2.Instance(this, 'GhostEnvInstance', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MICRO),
      machineImage: ec2.MachineImage.latestAmazonLinux2023(),
      securityGroup: ghostSg,
      blockDevices: [{
        deviceName: '/dev/xvda',
        volume: ec2.BlockDeviceVolume.ebs(8, { volumeType: ec2.EbsDeviceVolumeType.GP3 }),
      }],
    });
    cdk.Tags.of(this.ghostInstance).add('Environment', envTagValue);
    cdk.Tags.of(this.ghostInstance).add('Name', 'cloudrift-test-pr-42-instance');
    cdk.Tags.of(this.ghostInstance).add('Project', 'cloudrift-test');

    // ─── Lambda function tagged as part of the same ghost environment
    //     (never invoked — zero invocations over 7d window)
    const ghostLambda = new lambda.Function(this, 'GhostEnvLambda', {
      functionName: 'cloudrift-test-pr-42-handler',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromInline(`
        exports.handler = async () => {
          return { statusCode: 200, body: 'Ghost env function - never invoked' };
        };
      `),
      timeout: cdk.Duration.seconds(3),
      memorySize: 128,
    });
    cdk.Tags.of(ghostLambda).add('Environment', envTagValue);
    cdk.Tags.of(ghostLambda).add('Project', 'cloudrift-test');

    // Export the instance ID so post-deploy can stop it
    const output = new cdk.CfnOutput(this, 'GhostEnvInstanceId', {
      value: this.ghostInstance.instanceId,
      description: 'Ghost environment EC2 instance to stop post-deploy',
    });
    output.overrideLogicalId('GhostEnvInstanceId');
  }
}
