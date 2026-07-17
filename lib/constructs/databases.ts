import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as docdb from 'aws-cdk-lib/aws-docdb';
import * as neptune from 'aws-cdk-lib/aws-neptune';
import * as elasticache from 'aws-cdk-lib/aws-elasticache';
import { Construct } from 'constructs';

export interface DatabasesProps {
  readonly vpc: ec2.Vpc;
  /** Deploy the underutilized RDS instance (requires 7d of metrics). Default: false. */
  readonly includeUnderutilized?: boolean;
}

/**
 * Databases construct: RDS (stopped + underutilized), DocumentDB, Neptune, ElastiCache —
 * all left idle with zero connections/traffic.
 */
export class Databases extends Construct {
  public readonly rdsInstance: rds.DatabaseInstance;

  constructor(scope: Construct, id: string, props: DatabasesProps) {
    super(scope, id);

    const { vpc } = props;

    // ─── RDS instance that will be STOPPED post-deploy — waste: rds-instance
    const rdsSg = new ec2.SecurityGroup(this, 'RdsSg', {
      vpc,
      description: 'SG for the RDS instance that will be stopped',
      allowAllOutbound: false,
    });

    this.rdsInstance = new rds.DatabaseInstance(this, 'RdsInstance', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      engine: rds.DatabaseInstanceEngine.postgres({ version: rds.PostgresEngineVersion.VER_16_13 }),
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MICRO),
      allocatedStorage: 20,
      storageType: rds.StorageType.GP3,
      securityGroups: [rdsSg],
      credentials: rds.Credentials.fromGeneratedSecret('postgres'),
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      deletionProtection: false,
    });

    const output = new cdk.CfnOutput(this, 'RdsInstanceId', {
      value: this.rdsInstance.instanceIdentifier,
      description: 'RDS instance to stop post-deploy',
    });
    output.overrideLogicalId('RdsInstanceId');

    // ─── DocumentDB cluster, zero connections — waste: documentdb-idle-instance
    const docdbSg = new ec2.SecurityGroup(this, 'DocumentDbSg', {
      vpc,
      description: 'SG for the idle DocumentDB cluster',
      allowAllOutbound: false,
    });

    new docdb.DatabaseCluster(this, 'DocumentDbCluster', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MEDIUM),
      instances: 1,
      masterUser: { username: 'docdbadmin' },
      securityGroup: docdbSg,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ─── Neptune cluster, zero query traffic — waste: neptune-idle-instance
    const neptuneSg = new ec2.SecurityGroup(this, 'NeptuneSg', {
      vpc,
      description: 'SG for the idle Neptune cluster',
      allowAllOutbound: false,
    });

    const neptuneSubnetGroup = new neptune.CfnDBSubnetGroup(this, 'NeptuneSubnetGroup', {
      dbSubnetGroupDescription: 'cloudrift-test Neptune subnet group',
      subnetIds: vpc.selectSubnets({ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }).subnetIds,
    });

    const neptuneCluster = new neptune.CfnDBCluster(this, 'NeptuneCluster', {
      dbSubnetGroupName: neptuneSubnetGroup.ref,
      vpcSecurityGroupIds: [neptuneSg.securityGroupId],
      storageEncrypted: true,
    });
    neptuneCluster.applyRemovalPolicy(cdk.RemovalPolicy.DESTROY);

    const neptuneInstance = new neptune.CfnDBInstance(this, 'NeptuneInstance', {
      dbInstanceClass: 'db.t3.medium',
      dbClusterIdentifier: neptuneCluster.ref,
    });
    neptuneInstance.applyRemovalPolicy(cdk.RemovalPolicy.DESTROY);

    // ─── ElastiCache cluster, zero connections — waste: elasticache-idle
    const elastiCacheSg = new ec2.SecurityGroup(this, 'ElastiCacheSg', {
      vpc,
      description: 'SG for the idle ElastiCache cluster',
      allowAllOutbound: false,
    });

    const elastiCacheSubnetGroup = new elasticache.CfnSubnetGroup(this, 'ElastiCacheSubnetGroup', {
      description: 'cloudrift-test ElastiCache subnet group',
      subnetIds: vpc.selectSubnets({ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }).subnetIds,
    });

    const elastiCacheCluster = new elasticache.CfnCacheCluster(this, 'ElastiCacheCluster', {
      engine: 'redis',
      cacheNodeType: 'cache.t4g.micro',
      numCacheNodes: 1,
      cacheSubnetGroupName: elastiCacheSubnetGroup.ref,
      vpcSecurityGroupIds: [elastiCacheSg.securityGroupId],
    });
    elastiCacheCluster.applyRemovalPolicy(cdk.RemovalPolicy.DESTROY);

    // ─── RDS instance running but underutilized (near-zero CPU)
    //     optimization: rds-underutilized
    //     Requires 7+ days of metrics. Gated behind includeUnderutilized.
    if (props.includeUnderutilized) {
      const rdsUnderutilizedSg = new ec2.SecurityGroup(this, 'RdsUnderutilizedSg', {
        vpc,
        description: 'SG for the underutilized RDS instance (blocks all inbound)',
        allowAllOutbound: false,
      });

      new rds.DatabaseInstance(this, 'RdsUnderutilizedInstance', {
        vpc,
        vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
        engine: rds.DatabaseInstanceEngine.postgres({ version: rds.PostgresEngineVersion.VER_16_13 }),
        instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MICRO),
        allocatedStorage: 20,
        storageType: rds.StorageType.GP3,
        securityGroups: [rdsUnderutilizedSg],
        credentials: rds.Credentials.fromGeneratedSecret('postgres'),
        removalPolicy: cdk.RemovalPolicy.DESTROY,
        deletionProtection: false,
      });
    }
  }
}
