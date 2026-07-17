import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as sagemaker from 'aws-cdk-lib/aws-sagemaker';
import { Construct } from 'constructs';

export interface SageMakerProps {
  readonly vpc: ec2.Vpc;
}

/**
 * SageMaker construct: Notebook instance (idle), Endpoint (idle),
 * Model (orphaned — not referenced by any endpoint config).
 *
 * Scanners covered:
 *   - sagemaker-notebook-idle: InService notebook with zero CPU
 *   - sagemaker-endpoint-idle: InService endpoint with zero invocations
 *   - sagemaker-training-orphaned: Model not referenced by any endpoint config
 */
export class SageMaker extends Construct {
  constructor(scope: Construct, id: string, props: SageMakerProps) {
    super(scope, id);

    const { vpc } = props;

    // ─── IAM Role for SageMaker resources
    const sagemakerRole = new iam.Role(this, 'SageMakerRole', {
      assumedBy: new iam.ServicePrincipal('sagemaker.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSageMakerFullAccess'),
      ],
    });

    // ─── SageMaker Notebook Instance — InService, never used
    //     waste: sagemaker-notebook-idle
    //     The SG allows HTTPS outbound (443) so the notebook can reach SageMaker
    //     API/S3/CloudWatch via VPC endpoints or NAT. Without this the instance
    //     stays stuck in Pending. We block everything else to minimize activity.
    const notebookSg = new ec2.SecurityGroup(this, 'NotebookSg', {
      vpc,
      description: 'SG for the idle SageMaker notebook instance',
      allowAllOutbound: false,
    });
    notebookSg.addEgressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(443), 'Allow HTTPS for SageMaker/S3/CW');

    new sagemaker.CfnNotebookInstance(this, 'IdleNotebook', {
      notebookInstanceName: 'cloudrift-test-idle-notebook',
      instanceType: 'ml.t3.medium',
      roleArn: sagemakerRole.roleArn,
      subnetId: vpc.selectSubnets({ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }).subnetIds[0],
      securityGroupIds: [notebookSg.securityGroupId],
      directInternetAccess: 'Disabled',
      tags: [
        { key: 'Name', value: 'cloudrift-test-idle-notebook' },
        { key: 'Project', value: 'cloudrift-test' },
      ],
    });

    // ─── SageMaker Model — NOT referenced by any endpoint config
    //     optimization: sagemaker-training-orphaned
    //     Using the pre-built scikit-learn inference container as a lightweight image.
    //     The container registry for SageMaker pre-built images varies by region.
    //     eu-central-1: 492215442770, us-east-1: 683313688378, etc.
    //     See: https://docs.aws.amazon.com/sagemaker/latest/dg-ecr-paths/ecr-eu-central-1.html
    const SAGEMAKER_SKLEARN_REGISTRY: Record<string, string> = {
      'eu-central-1': '492215442770',
      'us-east-1': '683313688378',
      'us-west-2': '246618743249',
      'eu-west-1': '141502667606',
      'us-east-2': '257758044811',
      'ap-southeast-1': '121021644041',
      'ap-northeast-1': '354813040037',
    };
    const region = cdk.Stack.of(this).region;
    if (!cdk.Token.isUnresolved(region) && !SAGEMAKER_SKLEARN_REGISTRY[region]) {
      throw new Error(
        `SageMaker sklearn container registry not configured for region ${region}. ` +
        `Add it to SAGEMAKER_SKLEARN_REGISTRY in lib/constructs/sagemaker.ts. ` +
        `See: https://docs.aws.amazon.com/sagemaker/latest/dg-ecr-paths/`
      );
    }
    // For unresolved tokens (synth-time), default to eu-central-1; at deploy time
    // the region will be resolved and if unsupported, CloudFormation will fail with
    // a clear "image not found" error.
    const sklearnRegistry = SAGEMAKER_SKLEARN_REGISTRY[region] ?? SAGEMAKER_SKLEARN_REGISTRY['eu-central-1'];
    const sklearnImage = `${sklearnRegistry}.dkr.ecr.${region}.amazonaws.com/sagemaker-scikit-learn:1.2-1-cpu-py3`;

    // The model uses a publicly available SageMaker-managed container image.
    // NOT referenced by any endpoint config → detectable by sagemaker-training-orphaned.
    new sagemaker.CfnModel(this, 'OrphanedModel', {
      modelName: 'cloudrift-test-orphaned-model',
      executionRoleArn: sagemakerRole.roleArn,
      primaryContainer: {
        image: sklearnImage,
      },
    });

    // ─── SageMaker Endpoint — InService, zero invocations
    //     waste: sagemaker-endpoint-idle
    //     Uses a separate model (distinct from the orphaned one above).
    const endpointModel = new sagemaker.CfnModel(this, 'EndpointModel', {
      modelName: 'cloudrift-test-endpoint-model',
      executionRoleArn: sagemakerRole.roleArn,
      primaryContainer: {
        image: sklearnImage,
      },
    });

    const endpointConfig = new sagemaker.CfnEndpointConfig(this, 'IdleEndpointConfig', {
      endpointConfigName: 'cloudrift-test-idle-endpoint-config',
      productionVariants: [
        {
          variantName: 'AllTraffic',
          modelName: endpointModel.attrModelName,
          instanceType: 'ml.t2.medium',
          initialInstanceCount: 1,
        },
      ],
    });

    new sagemaker.CfnEndpoint(this, 'IdleEndpoint', {
      endpointName: 'cloudrift-test-idle-endpoint',
      endpointConfigName: endpointConfig.attrEndpointConfigName,
    });
  }
}
