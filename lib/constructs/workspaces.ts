import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as ds from 'aws-cdk-lib/aws-directoryservice';
import * as workspaces from 'aws-cdk-lib/aws-workspaces';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

/**
 * Public "Value" bundle IDs, one per region we expect to deploy to.
 * AWS publishes these per-account/region and they do change over time —
 * verify at https://docs.aws.amazon.com/workspaces/latest/adminguide/bundles.html
 * before a real deploy and update this map if creation fails with an
 * "invalid bundle" error.
 */
const VALUE_BUNDLE_ID_BY_REGION: Record<string, string> = {
  'us-east-1': 'wsb-b0s22j3d7',
  'eu-central-1': 'wsb-b0s22j3d7',
};

export interface WorkspacesProps {
  readonly vpc: ec2.Vpc;
}

/**
 * Workspaces construct: a Simple AD directory + one AlwaysOn WorkSpace,
 * never connected — waste: workspaces-idle.
 *
 * Opt-in only (config.includeWorkspaces): Simple AD takes 20-45min to
 * reach ACTIVE, which is why this isn't deployed by default alongside
 * everything else.
 */
export class Workspaces extends Construct {
  constructor(scope: Construct, id: string, props: WorkspacesProps) {
    super(scope, id);

    const { vpc } = props;
    const privateSubnetIds = vpc.selectSubnets({ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }).subnetIds;

    const directoryPassword = new secretsmanager.Secret(this, 'DirectoryPassword', {
      generateSecretString: { excludePunctuation: true, passwordLength: 20 },
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const directory = new ds.CfnSimpleAD(this, 'SimpleAD', {
      name: 'cloudrift.test',
      size: 'Small',
      password: directoryPassword.secretValue.unsafeUnwrap(),
      vpcSettings: {
        vpcId: vpc.vpcId,
        subnetIds: privateSubnetIds,
      },
    });
    directory.applyRemovalPolicy(cdk.RemovalPolicy.DESTROY);

    // ─── AD user for the WorkSpace — no native CFN resource for this,
    //     same gap-filling pattern as the orphan-snapshot Custom Resource.
    const userName = 'cloudrifttest';

    const createAdUserRole = new iam.Role(this, 'CreateAdUserRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
      inlinePolicies: {
        DsDataOps: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              actions: ['ds-data:CreateUser', 'ds-data:DeleteUser', 'ds-data:DescribeUser'],
              resources: ['*'],
            }),
          ],
        }),
      },
    });

    const createAdUserFn = new lambda.Function(this, 'CreateAdUserFn', {
      functionName: 'cloudrift-test-create-ad-user-cr',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      timeout: cdk.Duration.minutes(5),
      role: createAdUserRole,
      code: lambda.Code.fromAsset('lambda/create-ad-user'),
    });

    const adUser = new cdk.CustomResource(this, 'AdUserCr', {
      serviceToken: createAdUserFn.functionArn,
      properties: {
        DirectoryId: directory.ref,
        UserName: userName,
      },
    });
    adUser.node.addDependency(directory);

    // ─── AlwaysOn WorkSpace, never connected — waste: workspaces-idle
    const region = cdk.Stack.of(this).region;
    const bundleId = VALUE_BUNDLE_ID_BY_REGION[region] ?? VALUE_BUNDLE_ID_BY_REGION['us-east-1'];

    const workspace = new workspaces.CfnWorkspace(this, 'IdleWorkspace', {
      bundleId,
      directoryId: directory.ref,
      userName,
      workspaceProperties: { runningMode: 'ALWAYS_ON' },
    });
    workspace.node.addDependency(adUser);

    new cdk.CfnOutput(this, 'WorkspaceDirectoryId', { value: directory.ref }).overrideLogicalId(
      'WorkspaceDirectoryId'
    );
  }
}
