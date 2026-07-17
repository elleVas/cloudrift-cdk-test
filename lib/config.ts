/**
 * Centralized configuration interface for the CloudriftTest stack.
 * All feature toggles and tunable parameters live here.
 */
export interface IStackConfig {
  /** Deploy a NAT Gateway (~$1.08/day). Default: true (required for private subnet egress). */
  readonly includeNatGateway: boolean;

  /**
   * Deploy a WorkSpaces + Simple AD directory (`workspaces-idle` scanner).
   * Default: false — Simple AD takes 20-45min to become ACTIVE before the
   * WorkSpace itself can even be created, which greatly lengthens the
   * deploy/validate/destroy cycle compared to every other resource here.
   */
  readonly includeWorkspaces: boolean;

  /**
   * Deploy SageMaker resources (notebook, endpoint, model).
   * Default: false — SageMaker endpoints are expensive ($0.07-$0.50/h)
   * and notebooks/models require the service to be available in the region.
   */
  readonly includeSageMaker: boolean;

  /**
   * Deploy an EKS cluster with a managed node group and orphan PVC volume.
   * Default: false — EKS clusters take 10-15min to create and ~$0.10/h
   * for the control plane.
   */
  readonly includeEks: boolean;

  /**
   * Deploy Aurora Serverless v2 cluster (`aurora-serverless-overprovisioned` scanner).
   * Default: false — requires 7 days (168h) of metrics to trigger detection.
   * Only enable when running a long-lived test (7+ days).
   */
  readonly includeAuroraServerless: boolean;

  /**
   * Deploy resources that require 7-14 days of inactivity metrics to be detected:
   *   - ec2-underutilized (running instance, 7d low CPU)
   *   - rds-underutilized (running instance, 7d low CPU)
   *   - environment-ghost (tagged group inactive 7d)
   *   - sqs-dlq-abandoned (DLQ messages aging 14d)
   *
   * Default: false — these add cost ($1-2/day) and won't produce findings
   * until the stack has been alive for 7-14 days.
   */
  readonly includeTimeDependentResources: boolean;
}
