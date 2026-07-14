import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { Construct } from 'constructs';

export interface StorageProps {
  readonly vpc: ec2.Vpc;
}

/**
 * Storage construct: EBS volumes (unattached), S3 buckets (no lifecycle),
 * and orphan EBS snapshot via Custom Resource.
 */
export class Storage extends Construct {
  constructor(scope: Construct, id: string, props: StorageProps) {
    super(scope, id);

    const { vpc } = props;

    // ─── Unattached EBS Volume (gp2) — waste: ebs-volume
    new ec2.Volume(this, 'UnattachedGp2Volume', {
      availabilityZone: vpc.availabilityZones[0],
      size: cdk.Size.gibibytes(8),
      volumeType: ec2.EbsDeviceVolumeType.GP2,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ─── Unattached EBS Volume (gp3) — waste: ebs-volume
    new ec2.Volume(this, 'UnattachedGp3Volume', {
      availabilityZone: vpc.availabilityZones[0],
      size: cdk.Size.gibibytes(8),
      volumeType: ec2.EbsDeviceVolumeType.GP3,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ─── S3 Buckets with NO lifecycle policy — optimization: s3-no-lifecycle
    for (let i = 0; i < 5; i++) {
      new s3.Bucket(this, `NoLifecycleBucket${i}`, {
        bucketName: cdk.Fn.sub(`cloudrift-test-no-lifecycle-\${AWS::AccountId}-${i}`),
        removalPolicy: cdk.RemovalPolicy.DESTROY,
        autoDeleteObjects: true,
      });
    }

    // ─── Orphan EBS Snapshot via Custom Resource
    this.createOrphanSnapshot(vpc);
  }

  private createOrphanSnapshot(vpc: ec2.Vpc): void {
    const role = new iam.Role(this, 'OrphanSnapshotRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
      inlinePolicies: {
        // NOTE: Resource '*' is required because ec2:CreateVolume, ec2:CreateSnapshot,
        // and ec2:CreateTags do not support resource-level ARN constraints at creation
        // time (the ARN is not known until after the resource exists). This is scoped
        // to a Lambda running only during stack create/delete in a sandbox account.
        EbsOps: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              actions: [
                'ec2:CreateVolume',
                'ec2:DeleteVolume',
                'ec2:CreateSnapshot',
                'ec2:DeleteSnapshot',
                'ec2:DescribeVolumes',
                'ec2:DescribeSnapshots',
                'ec2:CreateTags',
              ],
              resources: ['*'],
            }),
          ],
        }),
      },
    });

    const fn = new lambda.Function(this, 'OrphanSnapshotFn', {
      functionName: 'cloudrift-test-orphan-snapshot-cr',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      timeout: cdk.Duration.minutes(5),
      role,
      code: lambda.Code.fromAsset('lambda/orphan-snapshot'),
    });

    const cr = new cdk.CustomResource(this, 'OrphanSnapshotCr', {
      serviceToken: fn.functionArn,
      properties: {
        AvailabilityZone: vpc.availabilityZones[0],
        Nonce: Date.now().toString(),
      },
    });

    const output = new cdk.CfnOutput(this, 'OrphanSnapshotId', {
      value: cr.getAttString('SnapshotId'),
      description: 'EBS snapshot whose source volume was deleted',
    });
    output.overrideLogicalId('OrphanSnapshotId');
  }
}
