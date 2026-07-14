#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { CloudriftTestStack } from '../lib/cloudrift-test.stack';
import { IStackConfig } from '../lib/config';

const app = new cdk.App();

const config: IStackConfig = {
  includeNatGateway:
    app.node.tryGetContext('includeNatGateway') === true ||
    process.env.INCLUDE_NAT_GATEWAY === 'true',
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
