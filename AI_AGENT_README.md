# AI Agent Branch - Implementation Guide

## Overview

This branch adds **AI-powered reasoning and planning** to the workflow automation engine. Instead of users defining fixed workflow steps, they describe tasks in natural language, and the AI agent figures out **how to execute them**.

**Branch Name:** `feature/ai-agent-reasoning`

---

## What This Branch Adds

### Before (Fixed Workflows)
```
User: "Create a GitHub issue daily"
System: Execute predefined steps
```

### After (AI Agent)
```
User: "Fetch news daily, analyze stocks, and email me if certain stocks dropped"
System: 
  1. PLAN: Break into steps, identify tools needed
  2. DISCOVER: Find available tools
  3. EXECUTE: Run tools with AI-generated arguments
  4. FEEDBACK: Check if successful
  5. ADAPT: If failed, replan or use fallback
  6. RESULT: Store reasoning and output
```

---

## For Cursor/AI Coding Agents

This guide is specifically written so you can implement this feature completely.

### Quick Start (If you're Cursor)

1. **Read** `AI_AGENT_IMPLEMENTATION_GUIDE.md` (in this repo)
2. **Execute** the SQL from `database-ai-agent.sql`
3. **Implement** the 8 steps below
4. **Test** with the provided test cases

---

## Implementation Steps

### Step 1: Database Migration

**Files involved:**
- `database.sql` → Keep existing tables
- `database-ai-agent.sql` → NEW: AI task tables (read the file)

**What to do:**
1. Read `database-ai-agent.sql` completely
2. The file contains:
   - `ai_tasks` - Stores user's AI tasks
   - `ai_reasoning_logs` - Stores AI's planning & thinking
   - `tool_registry` - Catalog of available tools
   - `task_execution_history` - Past executions for learning
   - `step_execution_logs` - Detailed step tracking
   - Helper functions (PL/pgSQL)
   - Sample tool registry data
   - Views for queries

3. Execute this SQL in Supabase or PostgreSQL

**Key tables explained:**

**ai_tasks**
- Stores every AI task user submits
- Tracks status: pending → planning → executing → completed
- Stores AI's plan, execution logs, result
- Supports cron scheduling for recurring tasks

**ai_reasoning_logs**
- Every time AI plans or recovers from error, log it here
- Stores extended thinking output (AI's full reasoning)
- Tracks which tools were planned
- Records if plan was executed and result

**tool_registry**
- Catalog of all available tools
- Includes schema (what parameters each tool accepts)
- Tagged with capabilities (create, fetch, analyze, send)
- AI uses this to discover which tools to use

---

### Step 2: Core AIAgentExecutor Class

**File to create:**
- `lib/ai-agent-executor.ts`

**What it does:**
This is the brain of the AI agent. It:
1. Takes a task description
2. Asks Claude to plan execution
3. Executes the planned steps
4. Handles errors and recovery
5. Stores all reasoning

**Implementation outline:**

```typescript
export class AIAgentExecutor {
  // Method 1: planTask(task)
  // INPUT: Natural language task description
  // OUTPUT: Execution plan with steps
  // PROCESS:
  //   - Get available tools for user
  //   - Ask Claude with extended thinking to plan
  //   - Store planning log
  //   - Return plan

  // Method 2: getAvailableTools(userId)
  // INPUT: User ID
  // OUTPUT: List of tools user has access to
  // PROCESS:
  //   - Query mcp_credentials (what MCPs user has)
  //   - Query tool_registry (all available tools)
  //   - Return intersection (user's available tools)

  // Method 3: executePlan(task, plan)
  // INPUT: Task and its plan
  // OUTPUT: Final result
  // PROCESS:
  //   - For each step in plan:
  //     - Resolve variables ({{step_1.output}})
  //     - Execute tool via MCP
  //     - Check if successful
  //     - If failed, try fallback or ask AI
  //   - Return context with all step outputs

  // Method 4: askAIForRecovery(step, error, executionLog)
  // INPUT: Failed step and error details
  // OUTPUT: Recovery action (retry/skip/replan)
  // PROCESS:
  //   - Show error to Claude
  //   - Ask what to do next
  //   - Return action

  // Method 5: replanAndExecute(task, previousError)
  // INPUT: Task and what went wrong
  // OUTPUT: Result of new plan
  // PROCESS:
  //   - Ask Claude to create different plan
  //   - Execute new plan
  //   - Return result

  // Helper: executeTool(toolkit, slug, args, userId)
  // Calls your existing executeMCPTool function

  // Helper: resolveVariables(args, context)
  // Replace {{step_1.output}} with actual output from step 1

  // Helper: evaluateSuccessCriteria(result, criteria)
  // Check if step actually succeeded
}
```

**Key implementation details:**

1. **Extended Thinking for Planning**
   ```typescript
   const response = await client.messages.create({
     model: "claude-3-5-sonnet-20241022",
     max_tokens: 4000,
     thinking: {
       type: "enabled",
       budget_tokens: 8000  // Deep reasoning
     },
     messages: [{role: "user", content: prompt}]
   });
   ```

2. **Store All Responses**
   ```typescript
   // Save to ai_reasoning_logs:
   - task_id
   - iteration (1st plan, 2nd plan, etc.)
   - ai_thinking (extended thinking output)
   - ai_response (full Claude response)
   - planned_steps (what it planned to do)
   ```

3. **Execute Tools**
   ```typescript
   // Call your existing executeMCPTool:
   const result = await executeMCPTool({
     toolkit: step.tool,
     tool_slug: step.tool_slug,
     arguments: resolvedArgs,
     user_id: userId
   });
   ```

4. **Variable Resolution**
   ```typescript
   // In arguments, replace:
   {{params.email}} → from user provided params
   {{step_1.output}} → from execution context
   ```

---

### Step 3: AI Task Queue Setup

**File to create:**
- `lib/ai-task-queue.ts`

**What it does:**
- BullMQ queue for async task processing
- Handles up to 3 concurrent AI agents

**Implementation:**

```typescript
import { Queue, Worker } from "bullmq";

export const aiTaskQueue = new Queue("ai_tasks", {
  connection: {
    host: process.env.REDIS_HOST || "localhost",
    port: parseInt(process.env.REDIS_PORT || "6379"),
    password: process.env.REDIS_PASSWORD
  }
});

export const aiTaskWorker = new Worker(
  "ai_tasks",
  async (job) => {
    // This will be implemented in Step 4
  },
  {
    connection: {...},
    concurrency: 3  // Max 3 parallel AI agents
  }
);
```

---

### Step 4: Task Queue Worker

**File to create:**
- `workers/ai-task-worker.ts`

**What it does:**
- Picks up jobs from queue
- Orchestrates the execution
- Updates task status throughout
- Handles errors

**Implementation flow:**

```typescript
export const aiTaskWorker = new Worker(
  "ai_tasks",
  async (job) => {
    const { task_id, user_id } = job.data;
    const executor = new AIAgentExecutor();

    // 1. Load task
    const task = await supabase
      .from("ai_tasks")
      .select("*")
      .eq("id", task_id)
      .single();

    // 2. Update status to planning
    await updateTaskStatus(task_id, "planning");

    try {
      // 3. Plan
      const plan = await executor.planTask(task);

      // 4. Update status to executing
      await updateTaskStatus(task_id, "executing", {ai_plan: plan});

      // 5. Execute
      const result = await executor.executePlan(task, plan);

      // 6. Update to completed
      await updateTaskStatus(task_id, "completed", {
        final_result: result,
        final_status: "success"
      });

      return result;
    } catch (error) {
      // 7. Update to failed
      await updateTaskStatus(task_id, "failed", {
        error_message: error.message
      });
      throw error;
    }
  },
  {...}
);

async function updateTaskStatus(task_id, status, updates = {}) {
  await supabase
    .from("ai_tasks")
    .update({
      status,
      ...updates,
      completed_at: ["completed", "failed"].includes(status) ? now() : null
    })
    .eq("id", task_id);
}
```

---

### Step 5: API Endpoints

**File to create:**
- `pages/api/ai-tasks.ts`
- `pages/api/ai-tasks/[id].ts`
- `pages/api/ai-tasks/[id]/retry.ts`

**POST /api/ai-tasks** (Create task)
```typescript
export default async function handler(req, res) {
  const user = await getAuthenticatedUser(req);

  if (req.method === "POST") {
    const { title, description, schedule_cron } = req.body;

    // Validate
    if (!title || !description) {
      return res.status(400).json({error: "title and description required"});
    }

    // Create task
    const { data: task } = await supabase
      .from("ai_tasks")
      .insert({
        user_id: user.id,
        title,
        description,
        schedule_cron,
        status: "pending"
      })
      .select()
      .single();

    // Queue job
    await aiTaskQueue.add("process-task", {
      task_id: task.id,
      user_id: user.id
    });

    return res.json({
      task_id: task.id,
      status: "queued",
      message: "Task queued for processing"
    });
  }
}
```

**GET /api/ai-tasks** (List tasks)
```typescript
if (req.method === "GET") {
  const { limit = 20, offset = 0, status } = req.query;

  let query = supabase
    .from("ai_tasks")
    .select("*", {count: "exact"})
    .eq("user_id", user.id)
    .order("created_at", {ascending: false})
    .range(offset, offset + limit - 1);

  if (status) {
    query = query.eq("status", status);
  }

  const { data, count } = await query;

  return res.json({
    tasks: data,
    total: count,
    limit,
    offset
  });
}
```

**GET /api/ai-tasks/[id]** (Get task details)
```typescript
// Fetch task + reasoning logs + step logs
const { data: task } = await supabase
  .from("ai_tasks")
  .select("*")
  .eq("id", id)
  .eq("user_id", user.id)
  .single();

const { data: reasoning } = await supabase
  .from("ai_reasoning_logs")
  .select("*")
  .eq("task_id", id)
  .order("iteration");

const { data: steps } = await supabase
  .from("step_execution_logs")
  .select("*")
  .eq("task_id", id)
  .order("step_number");

return res.json({
  task,
  reasoning_logs: reasoning,
  step_logs: steps
});
```

**POST /api/ai-tasks/[id]/retry** (Retry failed task)
```typescript
// Create new ai_task linked to parent
const { data: newTask } = await supabase
  .from("ai_tasks")
  .insert({
    user_id: user.id,
    title: `${original.title} (Retry)`,
    description: original.description,
    parent_task_id: id,
    status: "pending"
  })
  .select()
  .single();

// Queue new task
await aiTaskQueue.add("process-task", {
  task_id: newTask.id,
  user_id: user.id
});

return res.json({
  task_id: newTask.id,
  status: "queued"
});
```

---

### Step 6: AI Scheduler (For Cron Tasks)

**File to create:**
- `workers/ai-scheduler.ts`

**What it does:**
- Every 60 seconds, checks for scheduled AI tasks
- If cron time matches, creates new task and queues it

**Implementation:**

```typescript
export const aiSchedulerWorker = new Worker(
  "scheduler-ai",
  async () => {
    console.log("[AI Scheduler] Checking for scheduled tasks...");

    // Get all scheduled AI tasks
    const { data: schedules } = await supabase
      .from("ai_tasks")
      .select("*")
      .not("schedule_cron", "is", null)
      .eq("is_recurring", true);

    const now = new Date();
    let count = 0;

    for (const schedule of schedules) {
      try {
        // Parse cron, check if should run now
        const interval = cronParser.parseExpression(schedule.schedule_cron);
        const nextRun = new Date(interval.next().toDate());

        const timeDiff = Math.abs(nextRun.getTime() - now.getTime());

        if (timeDiff < 60000) {  // Within 1 minute
          // Create new task (child of parent)
          const { data: newTask } = await supabase
            .from("ai_tasks")
            .insert({
              user_id: schedule.user_id,
              title: schedule.title,
              description: schedule.description,
              parent_task_id: schedule.id,
              status: "pending"
            })
            .select()
            .single();

          // Queue job
          await aiTaskQueue.add("process-task", {
            task_id: newTask.id,
            user_id: schedule.user_id
          });

          // Update next_scheduled_at
          await supabase
            .from("ai_tasks")
            .update({next_scheduled_at: nextRun})
            .eq("id", schedule.id);

          count++;
        }
      } catch (err) {
        console.error(`[AI Scheduler] Error with task ${schedule.id}:`, err);
      }
    }

    console.log(`[AI Scheduler] Scheduled ${count} tasks`);
  },
  {
    connection: {...},
    repeat: {every: 60000}  // Run every 60 seconds
  }
);
```

---

### Step 7: Error Recovery & Replanning Logic

**Location:**
- In `lib/ai-agent-executor.ts` → Method `askAIForRecovery()`

**What it does:**
When a step fails, AI decides: retry / skip / replan

**Implementation:**

```typescript
async askAIForRecovery(step, error, executionLog) {
  const response = await this.client.messages.create({
    model: "claude-3-5-sonnet-20241022",
    max_tokens: 1000,
    thinking: {
      type: "enabled",
      budget_tokens: 5000  // Less thinking for recovery
    },
    messages: [{
      role: "user",
      content: `Failed step: ${step.tool_slug}
Error: ${error.message}
Execution log: ${JSON.stringify(executionLog)}

Decision: Retry / Skip / Replan?
Return: { action: "retry" | "skip" | "replan", reason: "..." }`
    }]
  });

  const decision = JSON.parse(response.content[0].text);

  if (decision.action === "replan") {
    // Call replanAndExecute()
    return await this.replanAndExecute(task, error);
  }

  return decision;
}
```

---

### Step 8: Testing

**Test cases to implement:**

1. **Simple Task** - Send email
   ```typescript
   POST /api/ai-tasks
   {
     "title": "Send welcome email",
     "description": "Send an email to user@example.com saying 'Welcome to our platform'"
   }
   ```
   Expected: Email sent

2. **Multi-step Task** - Fetch and summarize
   ```typescript
   POST /api/ai-tasks
   {
     "title": "News summary",
     "description": "Fetch latest tech news and summarize in 100 words"
   }
   ```
   Expected: Fetches news, summarizes

3. **Error Recovery** - Intentional failure
   ```typescript
   POST /api/ai-tasks
   {
     "title": "Test recovery",
     "description": "Call non-existent tool (AI should recover)"
   }
   ```
   Expected: AI tries fallback or replans

4. **Scheduled Task** - Cron
   ```typescript
   POST /api/ai-tasks
   {
     "title": "Daily report",
     "description": "Fetch news and email summary",
     "schedule_cron": "0 9 * * *"  // 9 AM daily
   }
   ```
   Expected: Runs at 9 AM daily

---

## File Structure

Create these files in order:

```
1. database-ai-agent.sql             (SQL schema)
2. lib/ai-agent-executor.ts          (Core executor)
3. lib/ai-task-queue.ts              (Queue setup)
4. workers/ai-task-worker.ts         (Job processor)
5. workers/ai-scheduler.ts           (Cron scheduler)
6. pages/api/ai-tasks.ts             (Main endpoints)
7. pages/api/ai-tasks/[id].ts        (Get details)
8. pages/api/ai-tasks/[id]/retry.ts  (Retry endpoint)
```

---

## Integration with Existing Code

**What you're using:**
- ✅ `lib/mcp-executor.ts` - Already exists, call it
- ✅ `lib/supabase.ts` - Already exists, import it
- ✅ `lib/queue.ts` - Already exists for Redis
- ✅ `worker.ts` - Just add ai-task-worker export
- ✅ Existing API pattern in `pages/api/`

**No breaking changes:**
- Workflow system still works
- Both systems run in parallel
- Share same MCP, Redis, Supabase

---

## Environment Variables to Add

```bash
# .env

# AI Agent configuration
AI_AGENT_ENABLED=true
AI_AGENT_CONCURRENCY=3
AI_AGENT_THINKING_BUDGET=8000

# Timing
AI_PLANNING_TOKENS=8000
AI_RECOVERY_TOKENS=5000
AI_REPLAN_TOKENS=8000
AI_TASK_TIMEOUT=600000  # 10 min
```

---

## Success Criteria

Your implementation is complete when:

✅ User can POST task with natural language  
✅ AI plans execution (visible in ai_reasoning_logs)  
✅ Tasks execute with tool calling  
✅ Errors trigger recovery  
✅ Results stored with full reasoning  
✅ Scheduled tasks run on cron  
✅ You can debug AI's thinking  

---

## Additional Resources

- **AI_AGENT_IMPLEMENTATION_GUIDE.md** - Detailed implementation patterns
- **database-ai-agent.sql** - Complete SQL schema
- **main README.md** - Main project documentation

For detailed architecture and common pitfalls, see `AI_AGENT_IMPLEMENTATION_GUIDE.md`
