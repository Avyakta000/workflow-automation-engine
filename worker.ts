import 'dotenv/config';
import { schedulerQueue } from './lib/queue';
import { recipeWorker } from './workers/recipe-worker';
import { schedulerWorker } from './workers/scheduler';

async function startWorkers() {
  console.log('\n🚀 Starting BullMQ Workers...\n');

  try {
    // Start scheduler to check every 60 seconds
    const job = await schedulerQueue.add(
      'check-schedules',
      {},
      {
        repeat: {
          every: 60000,
        },
        removeOnComplete: true,
      }
    );

    console.log('✅ Scheduler started (checks every 60s)');
    console.log('✅ Recipe worker ready (concurrency: ' +
      (process.env.WORKER_CONCURRENCY || '5') + ')');
    console.log('✅ Listening for jobs...\n');

    // Graceful shutdown
    process.on('SIGTERM', async () => {
      console.log('\n🛑 Shutting down gracefully...');
      await recipeWorker.close();
      await schedulerWorker.close();
      console.log('✅ Workers closed');
      process.exit(0);
    });

    process.on('SIGINT', async () => {
      console.log('\n🛑 Interrupted, shutting down...');
      await recipeWorker.close();
      await schedulerWorker.close();
      console.log('✅ Workers closed');
      process.exit(0);
    });
  } catch (err) {
    console.error('❌ Failed to start workers:', err);
    process.exit(1);
  }
}

startWorkers();
