/**
 * Centralized configuration interface for the CloudriftTest stack.
 * All feature toggles and tunable parameters live here.
 */
export interface IStackConfig {
  /** Deploy a NAT Gateway (~$1.08/day). Default: false */
  readonly includeNatGateway: boolean;

  /**
   * Deploy a WorkSpaces + Simple AD directory (`workspaces-idle` scanner).
   * Default: false — Simple AD takes 20-45min to become ACTIVE before the
   * WorkSpace itself can even be created, which greatly lengthens the
   * deploy/validate/destroy cycle compared to every other resource here.
   */
  readonly includeWorkspaces: boolean;
}
