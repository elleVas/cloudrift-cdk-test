/**
 * Centralized configuration interface for the CloudriftTest stack.
 * All feature toggles and tunable parameters live here.
 */
export interface IStackConfig {
  /** Deploy a NAT Gateway (~$1.08/day). Default: false */
  readonly includeNatGateway: boolean;
}
