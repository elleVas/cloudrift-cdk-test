#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { CloudriftTestStack } from '../lib/cloudrift-test.stack';
import { IStackConfig } from '../lib/config';

const app = new cdk.App();

// CLI-supplied context (`-c key=value`) always arrives as a string, while
// cdk.json's context arrives as a real JSON boolean — so a flag must be
// accepted as either 'true' (string) or true (boolean).
function contextFlag(app: cdk.App, key: string, envVar: string): boolean {
  const contextValue = app.node.tryGetContext(key);
  return contextValue === true || contextValue === 'true' || process.env[envVar] === 'true';
}

const config: IStackConfig = {
  includeNatGateway: contextFlag(app, 'includeNatGateway', 'INCLUDE_NAT_GATEWAY'),
  includeWorkspaces: contextFlag(app, 'includeWorkspaces', 'INCLUDE_WORKSPACES'),
};

new CloudriftTestStack(app, 'CloudriftTestStack', {
  description: 'Intentionally wasted AWS resources for validating cloudrift detection',
  config,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION ?? 'us-east-1',
  },
  tags: {
    Project: 'cloudrift-test',
    ManagedBy: 'cdk',
    Purpose: 'cloudrift-validation',
  },
});
