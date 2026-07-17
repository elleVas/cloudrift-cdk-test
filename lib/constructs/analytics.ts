import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as redshift from 'aws-cdk-lib/aws-redshift';
import * as opensearch from 'aws-cdk-lib/aws-opensearchservice';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

export interface AnalyticsProps {
  readonly vpc: ec2.Vpc;
}

/**
 * Analytics construct: Redshift and OpenSearch, both idle with zero
 * connections/query traffic.
 */
export class Analytics extends Construct {
  constructor(scope: Construct, id: string, props: AnalyticsProps) {
    super(scope, id);

    const { vpc } = props;

    // ─── Redshift cluster, zero connections — waste: redshift-idle-cluster
    const redshiftSg = new ec2.SecurityGroup(this, 'RedshiftSg', {
      vpc,
      description: 'SG for the idle Redshift cluster',
      allowAllOutbound: false,
    });

    const redshiftSubnetGroup = new redshift.CfnClusterSubnetGroup(this, 'RedshiftSubnetGroup', {
      description: 'cloudrift-test Redshift subnet group',
      subnetIds: vpc.selectSubnets({ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }).subnetIds,
    });

    // Redshift requires the AWSServiceRoleForRedshift SLR. On a fresh account
    // it's created automatically on first cluster creation. If the stack is
    // redeployed on an account that already has it, an explicit CfnServiceLinkedRole
    // would fail with AlreadyExists — so we don't manage it in the template.
    // The SLR was already created by a prior deploy attempt on this account.

    const redshiftSecret = new secretsmanager.Secret(this, 'RedshiftSecret', {
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ username: 'cloudriftadmin' }),
        generateStringKey: 'password',
        excludePunctuation: true,
        passwordLength: 20,
      },
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const redshiftCluster = new redshift.CfnCluster(this, 'RedshiftCluster', {
      clusterType: 'single-node',
      nodeType: 'ra3.xlplus',
      dbName: 'cloudrifttest',
      masterUsername: 'cloudriftadmin',
      masterUserPassword: redshiftSecret.secretValueFromJson('password').unsafeUnwrap(),
      clusterSubnetGroupName: redshiftSubnetGroup.ref,
      vpcSecurityGroupIds: [redshiftSg.securityGroupId],
      publiclyAccessible: false,
    });
    redshiftCluster.applyRemovalPolicy(cdk.RemovalPolicy.DESTROY);

    // ─── OpenSearch domain, zero search/index traffic — waste: opensearch-idle-domain
    //     Placed inside VPC for consistency with all other services in this stack.
    const openSearchSg = new ec2.SecurityGroup(this, 'OpenSearchSg', {
      vpc,
      description: 'SG for the idle OpenSearch domain',
      allowAllOutbound: false,
    });

    new opensearch.Domain(this, 'OpenSearchDomain', {
      version: opensearch.EngineVersion.OPENSEARCH_2_17,
      vpc,
      vpcSubnets: [{ subnets: [vpc.selectSubnets({ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }).subnets[0]] }],
      securityGroups: [openSearchSg],
      capacity: {
        dataNodes: 1,
        dataNodeInstanceType: 't3.small.search',
        multiAzWithStandbyEnabled: false,
      },
      ebs: {
        volumeSize: 10,
        volumeType: ec2.EbsDeviceVolumeType.GP3,
      },
      zoneAwareness: { enabled: false },
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
  }
}
