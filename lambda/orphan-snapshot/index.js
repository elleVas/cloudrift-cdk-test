const {
  EC2Client,
  CreateVolumeCommand,
  CreateSnapshotCommand,
  DeleteVolumeCommand,
  DeleteSnapshotCommand,
  DescribeSnapshotsCommand,
} = require('@aws-sdk/client-ec2');
const https = require('https');
const url = require('url');

/**
 * Custom Resource handler that creates an orphan EBS snapshot.
 *
 * On Create/Update:
 *   1. Creates a temporary 1GB gp3 volume
 *   2. Snapshots the volume
 *   3. Deletes the volume
 *   Result: a snapshot whose source volume no longer exists.
 *
 * On Delete:
 *   Cleans up any snapshots tagged with CreatedBy=cloudrift-cdk-test.
 */

async function sendResponse(event, status, data, physicalId) {
  const body = JSON.stringify({
    Status: status,
    Reason: 'See CloudWatch logs',
    PhysicalResourceId: physicalId || event.PhysicalResourceId || 'orphan-snapshot-cr',
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
  const ec2 = new EC2Client({});
  const az = event.ResourceProperties.AvailabilityZone;
  const physicalId = event.PhysicalResourceId || 'orphan-snapshot-cr';

  try {
    if (event.RequestType === 'Delete') {
      // Cleanup: delete all snapshots tagged by this project
      try {
        const desc = await ec2.send(
          new DescribeSnapshotsCommand({
            Filters: [{ Name: 'tag:CreatedBy', Values: ['cloudrift-cdk-test'] }],
            OwnerIds: ['self'],
          })
        );
        for (const snap of desc.Snapshots || []) {
          await ec2.send(new DeleteSnapshotCommand({ SnapshotId: snap.SnapshotId }));
          console.log('Deleted snapshot:', snap.SnapshotId);
        }
      } catch (e) {
        console.warn('Cleanup error (non-fatal):', e.message);
      }
      await sendResponse(event, 'SUCCESS', {}, physicalId);
      return;
    }

    // Create/Update: create temp volume → snapshot → delete volume
    console.log('Creating temporary volume in', az);
    const vol = await ec2.send(
      new CreateVolumeCommand({
        AvailabilityZone: az,
        Size: 1,
        VolumeType: 'gp3',
        TagSpecifications: [
          {
            ResourceType: 'volume',
            Tags: [
              { Key: 'Name', Value: 'cloudrift-test-temp-for-snapshot' },
              { Key: 'CreatedBy', Value: 'cloudrift-cdk-test' },
            ],
          },
        ],
      })
    );
    console.log('Volume created:', vol.VolumeId);

    // Wait for volume to be available
    await new Promise((r) => setTimeout(r, 5000));

    console.log('Creating snapshot of', vol.VolumeId);
    const snap = await ec2.send(
      new CreateSnapshotCommand({
        VolumeId: vol.VolumeId,
        Description: 'cloudrift-test orphan snapshot (source volume will be deleted)',
        TagSpecifications: [
          {
            ResourceType: 'snapshot',
            Tags: [
              { Key: 'Name', Value: 'cloudrift-test-orphan-snapshot' },
              { Key: 'CreatedBy', Value: 'cloudrift-cdk-test' },
              { Key: 'Project', Value: 'cloudrift-test' },
            ],
          },
        ],
      })
    );
    console.log('Snapshot created:', snap.SnapshotId);

    // Wait for snapshot to initiate before deleting volume
    await new Promise((r) => setTimeout(r, 10000));

    console.log('Deleting source volume:', vol.VolumeId);
    await ec2.send(new DeleteVolumeCommand({ VolumeId: vol.VolumeId }));
    console.log('Volume deleted — snapshot is now orphaned');

    await sendResponse(event, 'SUCCESS', { SnapshotId: snap.SnapshotId }, snap.SnapshotId);
  } catch (err) {
    console.error('Error:', err);
    await sendResponse(event, 'FAILED', {}, physicalId);
  }
};
