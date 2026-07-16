const {
  DirectoryServiceDataClient,
  CreateUserCommand,
  DeleteUserCommand,
} = require('@aws-sdk/client-directoryservice-data');
const https = require('https');
const url = require('url');

/**
 * Custom Resource handler that creates the AD user a WorkSpace is
 * provisioned for. CloudFormation has no native resource to create a user
 * inside a Simple AD / Managed AD directory, so this fills that gap the
 * same way scripts/post-deploy.sh fills the "no stopped EC2" gap.
 *
 * NOTE: verify the DirectoryServiceData API shape (CreateUserCommand /
 * DeleteUserCommand input fields) against current AWS SDK v3 docs before
 * the first real deploy with includeWorkspaces=true — this was written
 * from general knowledge of the API, not a live SDK reference.
 */

async function sendResponse(event, status, data, physicalId) {
  const body = JSON.stringify({
    Status: status,
    Reason: 'See CloudWatch logs',
    PhysicalResourceId: physicalId || event.PhysicalResourceId || 'create-ad-user-cr',
    StackId: event.StackId,
    RequestId: event.RequestId,
    LogicalResourceId: event.LogicalResourceId,
    Data: data || {},
  });

  const parsed = url.parse(event.ResponseURL);

  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: parsed.hostname,
        port: 443,
        path: parsed.path,
        method: 'PUT',
        headers: { 'Content-Type': '', 'Content-Length': body.length },
      },
      resolve
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

exports.handler = async (event) => {
  const { DirectoryId, UserName } = event.ResourceProperties;
  const physicalId = event.PhysicalResourceId || `ad-user-${UserName}`;

  // DirectoryServiceData is a regional control-plane API, reachable without
  // the Lambda being attached to the directory's VPC.
  const ds = new DirectoryServiceDataClient({});

  try {
    if (event.RequestType === 'Delete') {
      try {
        await ds.send(new DeleteUserCommand({ DirectoryId, SAMAccountName: UserName }));
        console.log('Deleted AD user:', UserName);
      } catch (e) {
        console.warn('AD user cleanup error (non-fatal):', e.message);
      }
      await sendResponse(event, 'SUCCESS', {}, physicalId);
      return;
    }

    if (event.RequestType === 'Create') {
      console.log('Creating AD user', UserName, 'in directory', DirectoryId);
      await ds.send(
        new CreateUserCommand({
          DirectoryId,
          SAMAccountName: UserName,
          GivenName: 'cloudrift',
          Surname: 'test',
        })
      );
      console.log('AD user created:', UserName);
    }
    // Update: username/directory don't change (they force replacement via
    // the CDK construct's logical ID), so nothing to do here.

    await sendResponse(event, 'SUCCESS', { UserName }, physicalId);
  } catch (err) {
    console.error('Error:', err);
    await sendResponse(event, 'FAILED', {}, physicalId);
  }
};
