import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as eks from 'aws-cdk-lib/aws-eks';
import { KubectlV30Layer } from '@aws-cdk/lambda-layer-kubectl-v30';
import { Construct } from 'constructs';

export interface EksProps {
  readonly vpc: ec2.Vpc;
}

/**
 * EKS construct: cluster with an overprovisioned managed node group,
 * plus an unattached EBS volume tagged as a Kubernetes PVC (orphan).
 *
 * Scanners covered:
 *   - eks-node-overprovisioned: node group with far more capacity than requested
 *   - eks-orphan-pvc: EBS volume tagged with PVC metadata, unattached
 *
 * NOTE: Container Insights must be enabled for `eks-node-overprovisioned` to
 * be detected (CloudWatch agent DaemonSet). The CDK `eks.Cluster` construct
 * can enable add-ons, but Container Insights requires the CloudWatch
 * Observability add-on — we enable it via a CfnAddon so the scanner has
 * metrics to evaluate. If the cluster doesn't emit metrics within the
 * window, the scanner gracefully degrades (no finding, no false positive).
 */
export class Eks extends Construct {
  constructor(scope: Construct, id: string, props: EksProps) {
    super(scope, id);

    const { vpc } = props;

    // ─── EKS Cluster
    const cluster = new eks.Cluster(this, 'Cluster', {
      clusterName: 'cloudrift-test-cluster',
      vpc,
      vpcSubnets: [{ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }],
      defaultCapacity: 0, // We'll add our own managed node group
      version: eks.KubernetesVersion.V1_30,
      endpointAccess: eks.EndpointAccess.PUBLIC_AND_PRIVATE,
      kubectlLayer: new KubectlV30Layer(this, 'KubectlLayer'),
    });

    // ─── Managed Node Group — overprovisioned (2 nodes for zero workload)
    //     waste: eks-node-overprovisioned
    cluster.addNodegroupCapacity('OverprovisionedNodegroup', {
      nodegroupName: 'cloudrift-test-overprovisioned-ng',
      instanceTypes: [ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MEDIUM)],
      minSize: 2,
      maxSize: 2,
      desiredSize: 2,
      diskSize: 20,
      subnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
    });

    // ─── Enable Container Insights via the CloudWatch Observability add-on
    //     Required for the scanner to get node_cpu_request/limit metrics.
    new eks.CfnAddon(this, 'CloudWatchObservability', {
      addonName: 'amazon-cloudwatch-observability',
      clusterName: cluster.clusterName,
      // Let EKS pick the latest compatible version
    });

    // ─── Orphaned PVC Volume — EBS volume tagged as Kubernetes PVC but unattached
    //     waste: eks-orphan-pvc
    //     The scanner identifies PVC volumes via the `kubernetes.io/created-for/pvc/name` tag.
    //     An unattached volume with this tag is considered orphaned.
    const orphanPvcVolume = new ec2.Volume(this, 'OrphanPvcVolume', {
      availabilityZone: vpc.availabilityZones[0],
      size: cdk.Size.gibibytes(10),
      volumeType: ec2.EbsDeviceVolumeType.GP3,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
    // Standard CSI driver tags that identify a volume as a Kubernetes PVC
    cdk.Tags.of(orphanPvcVolume).add('kubernetes.io/created-for/pvc/name', 'cloudrift-test-orphan-pvc');
    cdk.Tags.of(orphanPvcVolume).add('kubernetes.io/created-for/pvc/namespace', 'default');
    cdk.Tags.of(orphanPvcVolume).add('kubernetes.io/cluster/cloudrift-test-cluster', 'owned');
    cdk.Tags.of(orphanPvcVolume).add('Name', 'cloudrift-test-orphan-pvc-volume');
    cdk.Tags.of(orphanPvcVolume).add('Project', 'cloudrift-test');
  }
}
