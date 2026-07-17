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

// Same as contextFlag but with a configurable default (for opt-out flags).
function contextFlagDefault(app: cdk.App, key: string, envVar: string, defaultValue: boolean): boolean {
  const contextValue = app.node.tryGetContext(key);
  if (contextValue !== undefined) return contextValue === true || contextValue === 'true';
  if (process.env[envVar] !== undefined) return process.env[envVar] === 'true';
  return defaultValue;
}

const config: IStackConfig = {
  includeNatGateway: contextFlagDefault(app, 'includeNatGateway', 'INCLUDE_NAT_GATEWAY', true),
  includeWorkspaces: contextFlag(app, 'includeWorkspaces', 'INCLUDE_WORKSPACES'),
  includeSageMaker: contextFlag(app, 'includeSageMaker', 'INCLUDE_SAGEMAKER'),
  includeEks: contextFlag(app, 'includeEks', 'INCLUDE_EKS'),
  includeAuroraServerless: contextFlag(app, 'includeAuroraServerless', 'INCLUDE_AURORA_SERVERLESS'),
  includeTimeDependentResources: contextFlag(app, 'includeTimeDependentResources', 'INCLUDE_TIME_DEPENDENT'),
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
