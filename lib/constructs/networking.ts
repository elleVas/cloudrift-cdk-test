import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import { Construct } from 'constructs';
import { IStackConfig } from '../config';

export interface NetworkingProps {
  readonly config: IStackConfig;
}

/**
 * Networking construct: VPC, Elastic IP, orphaned ENI, ALB with no targets.
 */
export class Networking extends Construct {
  public readonly vpc: ec2.Vpc;
  public readonly stoppedInstanceSg: ec2.SecurityGroup;

  constructor(scope: Construct, id: string, props: NetworkingProps) {
    super(scope, id);

    const { config } = props;

    // ─── VPC — minimal, 2 AZs, public + private subnets (no NAT by default)
    this.vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      natGateways: config.includeNatGateway ? 1 : 0,
      subnetConfiguration: [
        { name: 'Public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        { name: 'Private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 24 },
      ],
    });

    // ─── Elastic IP not associated — waste: elastic-ip
    new ec2.CfnEIP(this, 'UnassociatedEip', {
      tags: [{ key: 'Name', value: 'cloudrift-test-unused-eip' }],
    });

    // ─── Security Group for stopped instance (reused by ENI)
    this.stoppedInstanceSg = new ec2.SecurityGroup(this, 'StoppedInstanceSg', {
      vpc: this.vpc,
      description: 'SG for the EC2 instance that will be stopped',
      allowAllOutbound: false,
    });

    // ─── Orphaned ENI — waste: eni-orphaned
    new ec2.CfnNetworkInterface(this, 'OrphanedEni', {
      subnetId: this.vpc.publicSubnets[0].subnetId,
      description: 'cloudrift-test orphaned ENI (not attached to anything)',
      groupSet: [this.stoppedInstanceSg.securityGroupId],
    });

    // ─── ALB with no targets — waste: load-balancer
    const alb = new elbv2.ApplicationLoadBalancer(this, 'EmptyAlb', {
      vpc: this.vpc,
      internetFacing: true,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
    });

    alb.addListener('HttpListener', {
      port: 80,
      defaultAction: elbv2.ListenerAction.fixedResponse(404, {
        messageBody: 'No targets',
      }),
    });

    // ─── NAT Gateway cost note
    if (config.includeNatGateway) {
      new cdk.CfnOutput(this, 'NatGatewayNote', {
        value: 'NAT Gateway deployed — ~$1.08/day. Destroy ASAP after testing.',
      });
    }

    new cdk.CfnOutput(this, 'VpcId', {
      value: this.vpc.vpcId,
    });
  }
}
