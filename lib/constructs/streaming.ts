import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as kinesis from 'aws-cdk-lib/aws-kinesis';
import * as msk from 'aws-cdk-lib/aws-msk';
import * as mq from 'aws-cdk-lib/aws-amazonmq';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

export interface StreamingProps {
  readonly vpc: ec2.Vpc;
}

/**
 * Streaming construct: Kinesis, MSK (Kafka), Amazon MQ — all idle with
 * zero incoming traffic/connections.
 */
export class Streaming extends Construct {
  constructor(scope: Construct, id: string, props: StreamingProps) {
    super(scope, id);

    const { vpc } = props;
    const privateSubnetIds = vpc.selectSubnets({ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }).subnetIds;

    // ─── Kinesis stream, provisioned + zero incoming activity
    //     waste: kinesis-provisioned-idle-stream
    new kinesis.Stream(this, 'IdleStream', {
      streamMode: kinesis.StreamMode.PROVISIONED,
      shardCount: 1,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ─── MSK cluster (provisioned), zero broker traffic — waste: msk-idle-cluster
    const mskSg = new ec2.SecurityGroup(this, 'MskSg', {
      vpc,
      description: 'SG for the idle MSK cluster',
      allowAllOutbound: false,
    });

    // MSK requires numberOfBrokerNodes to be a multiple of the number of
    // subnets. We hardcode 2 brokers (one per AZ) so the cost stays
    // predictable regardless of VPC maxAzs changes.
    const mskBrokerCount = 2;

    const mskCluster = new msk.CfnCluster(this, 'MskCluster', {
      clusterName: 'cloudrift-test-idle-cluster',
      kafkaVersion: '3.6.0',
      numberOfBrokerNodes: mskBrokerCount,
      brokerNodeGroupInfo: {
        instanceType: 'kafka.t3.small',
        clientSubnets: privateSubnetIds.slice(0, mskBrokerCount),
        securityGroups: [mskSg.securityGroupId],
        storageInfo: {
          ebsStorageInfo: { volumeSize: 10 },
        },
      },
    });
    mskCluster.applyRemovalPolicy(cdk.RemovalPolicy.DESTROY);

    // ─── Amazon MQ broker (single-instance), zero network traffic
    //     waste: mq-idle-broker
    const mqSg = new ec2.SecurityGroup(this, 'MqSg', {
      vpc,
      description: 'SG for the idle Amazon MQ broker',
      allowAllOutbound: false,
    });

    const mqUserSecret = new secretsmanager.Secret(this, 'MqUserSecret', {
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ username: 'cloudriftadmin' }),
        generateStringKey: 'password',
        excludePunctuation: true,
      },
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const mqBroker = new mq.CfnBroker(this, 'MqBroker', {
      brokerName: 'cloudrift-test-idle-broker',
      engineType: 'ACTIVEMQ',
      engineVersion: '5.17.6',
      hostInstanceType: 'mq.t3.micro',
      deploymentMode: 'SINGLE_INSTANCE',
      publiclyAccessible: false,
      subnetIds: [privateSubnetIds[0]],
      securityGroups: [mqSg.securityGroupId],
      users: [
        {
          username: 'cloudriftadmin',
          password: mqUserSecret.secretValueFromJson('password').unsafeUnwrap(),
        },
      ],
    });
    mqBroker.applyRemovalPolicy(cdk.RemovalPolicy.DESTROY);
  }
}
