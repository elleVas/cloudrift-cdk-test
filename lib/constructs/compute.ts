import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';

export interface ComputeProps {
  readonly vpc: ec2.Vpc;
  readonly stoppedInstanceSg: ec2.SecurityGroup;
}

/**
 * Compute construct: EC2 instances (stopped + idle with gp2 volume).
 */
export class Compute extends Construct {
  public readonly stoppedInstance: ec2.Instance;

  constructor(scope: Construct, id: string, props: ComputeProps) {
    super(scope, id);

    const { vpc, stoppedInstanceSg } = props;

    // ─── EC2 instance that will be STOPPED post-deploy — waste: ec2-instance
    this.stoppedInstance = new ec2.Instance(this, 'StoppedInstance', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MICRO),
      machineImage: ec2.MachineImage.latestAmazonLinux2023(),
      securityGroup: stoppedInstanceSg,
      blockDevices: [{
        deviceName: '/dev/xvda',
        volume: ec2.BlockDeviceVolume.ebs(8, { volumeType: ec2.EbsDeviceVolumeType.GP3 }),
      }],
    });

    // ─── Running EC2 instance with gp2 volume (idle I/O)
    //     waste: ebs-idle + optimization: ebs-gp2-upgrade
    const idleInstanceSg = new ec2.SecurityGroup(this, 'IdleInstanceSg', {
      vpc,
      description: 'SG for the idle EC2 instance',
      allowAllOutbound: false,
    });

    new ec2.Instance(this, 'IdleInstance', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MICRO),
      machineImage: ec2.MachineImage.latestAmazonLinux2023(),
      securityGroup: idleInstanceSg,
      blockDevices: [{
        deviceName: '/dev/xvda',
        volume: ec2.BlockDeviceVolume.ebs(10, { volumeType: ec2.EbsDeviceVolumeType.GP2 }),
      }],
    });

    new cdk.CfnOutput(this, 'StoppedInstanceId', {
      value: this.stoppedInstance.instanceId,
      description: 'EC2 instance to stop post-deploy',
    });
  }
}
