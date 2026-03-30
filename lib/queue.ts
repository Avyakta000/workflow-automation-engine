import { Queue } from 'bullmq';

const redisConnection = {
  host: process.env.REDIS_HOST || 'localhost',
  port: parseInt(process.env.REDIS_PORT || '6379'),
  password: process.env.REDIS_PASSWORD,
};

// Main workflow execution queue
export const workflowQueue = new Queue('workflows', {
  connection: redisConnection,
  settings: {
    maxStalledCount: 2,
    stalledInterval: 30000,
  },
});

// Scheduler queue for periodic checks
export const schedulerQueue = new Queue('scheduler', {
  connection: redisConnection,
});

// Webhook trigger queue
export const webhookQueue = new Queue('webhooks', {
  connection: redisConnection,
});

// Job events
workflowQueue.on('completed', (job) => {
  console.log(`[Queue] Job ${job.id} completed`);
});

workflowQueue.on('failed', (job, err) => {
  console.error(`[Queue] Job ${job.id} failed: ${err.message}`);
});

workflowQueue.on('error', (err) => {
  console.error('[Queue] Error:', err);
});

export default workflowQueue;
