import { Worker, Job } from 'bullmq';
import supabase from '../lib/supabase';
import { executeRecipeWorkflow } from '../lib/recipe-executor';

const redisConnection = {
  host: process.env.REDIS_HOST || 'localhost',
  port: parseInt(process.env.REDIS_PORT || '6379'),
  password: process.env.REDIS_PASSWORD,
};

export const recipeWorker = new Worker(
  'recipes',
  async (job: Job) => {
    const {
      recipe_id,
      scheduled_recipe_id,
      user_id,
      execution_log_id,
      params = {},
    } = job.data;

    const startTime = Date.now();
    console.log(`[Worker] Processing job ${job.id} for recipe ${recipe_id}`);

    try {
      // Update log: mark as running
      await supabase
        .from('execution_logs')
        .update({
          status: 'running',
          started_at: new Date().toISOString(),
        })
        .eq('id', execution_log_id);

      // Execute recipe workflow
      const output = await executeRecipeWorkflow({
        recipe_id,
        scheduled_recipe_id,
        user_id,
        execution_log_id,
        params,
      });

      const duration = Date.now() - startTime;

      // Update log: mark as success
      await supabase
        .from('execution_logs')
        .update({
          status: 'success',
          output_data: output,
          completed_at: new Date().toISOString(),
          duration_ms: duration,
        })
        .eq('id', execution_log_id);

      // Update scheduled recipe stats
      await supabase.rpc('increment_successful_runs', {
        schedule_id: scheduled_recipe_id,
      });

      console.log(
        `[Worker] Job ${job.id} completed in ${duration}ms`
      );

      return {
        success: true,
        output,
        duration_ms: duration,
      };
    } catch (err) {
      const duration = Date.now() - startTime;
      const errorMessage =
        err instanceof Error ? err.message : String(err);
      const errorStack =
        err instanceof Error ? err.stack : null;

      console.error(`[Worker] Job ${job.id} failed:`, errorMessage);

      // Update log: mark as failed
      await supabase
        .from('execution_logs')
        .update({
          status: 'failed',
          error_message: errorMessage,
          error_stack: errorStack ? { stack: errorStack } : null,
          completed_at: new Date().toISOString(),
          duration_ms: duration,
        })
        .eq('id', execution_log_id);

      // Update scheduled recipe stats
      await supabase.rpc('increment_failed_runs', {
        schedule_id: scheduled_recipe_id,
      });

      throw err;
    }
  },
  {
    connection: redisConnection,
    concurrency: parseInt(process.env.WORKER_CONCURRENCY || '5'),
    settings: {
      maxStalledCount: 2,
      stalledInterval: 30000,
    },
  }
);

recipeWorker.on('completed', (job) => {
  console.log(`✅ Job ${job.id} completed`);
});

recipeWorker.on('failed', (job, err) => {
  console.error(`❌ Job ${job.id} failed:`, err.message);
});
