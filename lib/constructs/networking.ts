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

    // ─── VPN Site-to-Site connection, zero tunnel traffic — waste: vpn-connection-idle
    //     Dummy customer gateway IP: no real tunnel needs to come up, the
    //     connection just needs to reach `available` state.
    const vpnGateway = new ec2.CfnVPNGateway(this, 'VpnGateway', { type: 'ipsec.1' });
    const vpcVpnAttachment = new ec2.CfnVPCGatewayAttachment(this, 'VpnGatewayAttachment', {
      vpcId: this.vpc.vpcId,
      vpnGatewayId: vpnGateway.ref,
    });
    const customerGateway = new ec2.CfnCustomerGateway(this, 'CustomerGateway', {
      type: 'ipsec.1',
      bgpAsn: 65000,
      ipAddress: '203.0.113.1', // TEST-NET-3 (RFC 5737) — unroutable placeholder, no real tunnel needed
    });
    const idleVpnConnection = new ec2.CfnVPNConnection(this, 'IdleVpnConnection', {
      type: 'ipsec.1',
      customerGatewayId: customerGateway.ref,
      vpnGatewayId: vpnGateway.ref,
      staticRoutesOnly: true,
    });
    idleVpnConnection.addDependency(vpcVpnAttachment);

    // ─── Transit Gateway + VPC attachment, zero traffic
    //     waste: transit-gateway-idle-attachment
    const transitGateway = new ec2.CfnTransitGateway(this, 'TransitGateway', {
      description: 'cloudrift-test idle transit gateway',
    });
    new ec2.CfnTransitGatewayAttachment(this, 'IdleTransitGatewayAttachment', {
      transitGatewayId: transitGateway.ref,
      vpcId: this.vpc.vpcId,
      subnetIds: this.vpc.selectSubnets({ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }).subnetIds,
    });

    // ─── NAT Gateway cost note
    if (config.includeNatGateway) {
      const natOutput = new cdk.CfnOutput(this, 'NatGatewayNote', {
        value: 'NAT Gateway deployed — ~$1.08/day. Destroy ASAP after testing.',
      });
      natOutput.overrideLogicalId('NatGatewayNote');
    }

    const vpcOutput = new cdk.CfnOutput(this, 'VpcId', {
      value: this.vpc.vpcId,
    });
    vpcOutput.overrideLogicalId('VpcId');
  }
}
