-- ============================================
-- AI AGENT TASK EXECUTION SCHEMA
-- ============================================

-- Core AI tasks table
CREATE TABLE IF NOT EXISTS ai_tasks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  
  -- Task definition
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'planning', 'executing', 'completed', 'failed')),
  
  -- AI Planning
  ai_plan JSONB,
  plan_iterations INTEGER DEFAULT 0,
  
  -- Execution tracking
  current_step INTEGER DEFAULT 0,
  execution_log JSONB DEFAULT '[]',
  
  -- Result
  final_result JSONB,
  final_status TEXT,
  error_message TEXT,
  error_recovery_attempts INTEGER DEFAULT 0,
  
  -- Metadata
  created_at TIMESTAMP DEFAULT NOW(),
  started_at TIMESTAMP,
  completed_at TIMESTAMP,
  total_duration_ms INTEGER,
  
  -- Scheduling
  schedule_cron TEXT,
  is_recurring BOOLEAN DEFAULT FALSE,
  last_executed_at TIMESTAMP,
  next_scheduled_at TIMESTAMP,
  
  -- For recurring tasks
  parent_task_id UUID REFERENCES ai_tasks(id),
  
  CONSTRAINT valid_status CHECK (status IS NOT NULL)
);

CREATE INDEX idx_ai_tasks_user_id ON ai_tasks(user_id);
CREATE INDEX idx_ai_tasks_status ON ai_tasks(status);
CREATE INDEX idx_ai_tasks_created_at ON ai_tasks(created_at);
CREATE INDEX idx_ai_tasks_schedule_cron ON ai_tasks(schedule_cron) WHERE schedule_cron IS NOT NULL;

-- ============================================
-- AI REASONING & PLANNING LOG
-- ============================================

CREATE TABLE IF NOT EXISTS ai_reasoning_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id UUID NOT NULL REFERENCES ai_tasks(id) ON DELETE CASCADE,
  
  -- Planning iteration
  iteration INTEGER NOT NULL,
  phase TEXT CHECK (phase IN ('planning', 'error_recovery', 'replanning')),
  
  -- AI interaction details
  prompt_sent TEXT NOT NULL,
  ai_thinking TEXT,
  ai_response TEXT NOT NULL,
  
  -- What was planned
  planned_steps JSONB,
  tools_identified TEXT[],
  estimated_duration_ms INTEGER,
  confidence_score FLOAT,
  
  -- Execution result
  was_executed BOOLEAN DEFAULT FALSE,
  execution_success BOOLEAN,
  execution_error TEXT,
  
  -- Metadata
  model_used TEXT DEFAULT 'claude-3-5-sonnet-20241022',
  thinking_tokens_used INTEGER,
  total_tokens_used INTEGER,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_reasoning_logs_task_id ON ai_reasoning_logs(task_id);
CREATE INDEX idx_reasoning_logs_iteration ON ai_reasoning_logs(task_id, iteration);

-- ============================================
-- TOOL REGISTRY
-- ============================================

CREATE TABLE IF NOT EXISTS tool_registry (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  toolkit TEXT NOT NULL,
  tool_slug TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  description TEXT NOT NULL,
  
  input_schema JSONB NOT NULL,
  output_schema JSONB,
  
  capability_tags TEXT[],
  category TEXT,
  
  rate_limit_per_minute INTEGER,
  estimated_duration_ms INTEGER DEFAULT 5000,
  requires_auth BOOLEAN DEFAULT TRUE,
  
  is_available BOOLEAN DEFAULT TRUE,
  is_beta BOOLEAN DEFAULT FALSE,
  deprecation_warning TEXT,
  
  version TEXT,
  documentation_url TEXT,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  UNIQUE(toolkit, tool_slug)
);

CREATE INDEX idx_tool_registry_toolkit ON tool_registry(toolkit);
CREATE INDEX idx_tool_registry_capability ON tool_registry USING GIN(capability_tags);
CREATE INDEX idx_tool_registry_available ON tool_registry(is_available);

-- ============================================
-- TASK EXECUTION HISTORY
-- ============================================

CREATE TABLE IF NOT EXISTS task_execution_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  
  original_task TEXT NOT NULL,
  task_hash VARCHAR(64),
  
  successful_plan JSONB,
  tools_used TEXT[],
  steps_executed JSONB,
  
  success BOOLEAN NOT NULL,
  outcome TEXT,
  execution_time_ms INTEGER,
  planning_time_ms INTEGER,
  error_description TEXT,
  recovery_attempts INTEGER DEFAULT 0,
  
  tags TEXT[],
  category TEXT,
  task_embedding BYTEA,
  
  created_at TIMESTAMP DEFAULT NOW(),
  last_executed_at TIMESTAMP,
  execution_count INTEGER DEFAULT 1
);

CREATE INDEX idx_execution_history_user_id ON task_execution_history(user_id);
CREATE INDEX idx_execution_history_task_hash ON task_execution_history(task_hash);
CREATE INDEX idx_execution_history_success ON task_execution_history(success);
CREATE INDEX idx_execution_history_tags ON task_execution_history USING GIN(tags);

-- ============================================
-- STEP EXECUTION LOG
-- ============================================

CREATE TABLE IF NOT EXISTS step_execution_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id UUID NOT NULL REFERENCES ai_tasks(id) ON DELETE CASCADE,
  reasoning_log_id UUID REFERENCES ai_reasoning_logs(id),
  
  step_number INTEGER NOT NULL,
  tool_slug TEXT NOT NULL,
  toolkit TEXT NOT NULL,
  
  input_arguments JSONB,
  output_result JSONB,
  
  status TEXT CHECK (status IN ('pending', 'executing', 'success', 'failed', 'fallback', 'skipped')),
  error_message TEXT,
  
  started_at TIMESTAMP DEFAULT NOW(),
  completed_at TIMESTAMP,
  duration_ms INTEGER,
  
  retry_count INTEGER DEFAULT 0,
  fallback_used BOOLEAN DEFAULT FALSE,
  success_criteria_met BOOLEAN
);

CREATE INDEX idx_step_logs_task_id ON step_execution_logs(task_id);
CREATE INDEX idx_step_logs_step_number ON step_execution_logs(task_id, step_number);

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

CREATE OR REPLACE FUNCTION update_ai_task_status(
  task_id UUID,
  new_status TEXT,
  result JSONB DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
  UPDATE ai_tasks
  SET
    status = new_status,
    final_result = COALESCE(result, final_result),
    completed_at = CASE WHEN new_status IN ('completed', 'failed') THEN NOW() ELSE completed_at END,
    total_duration_ms = CASE WHEN new_status IN ('completed', 'failed') 
      THEN EXTRACT(EPOCH FROM (NOW() - started_at))::INTEGER * 1000
      ELSE total_duration_ms 
    END
  WHERE id = task_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION increment_recovery_attempts(task_id UUID)
RETURNS VOID AS $$
BEGIN
  UPDATE ai_tasks
  SET error_recovery_attempts = error_recovery_attempts + 1
  WHERE id = task_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_next_scheduled_ai_task()
RETURNS TABLE(
  id UUID,
  user_id UUID,
  title TEXT,
  description TEXT,
  schedule_cron TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT at.id, at.user_id, at.title, at.description, at.schedule_cron
  FROM ai_tasks at
  WHERE at.schedule_cron IS NOT NULL
    AND at.is_recurring = TRUE
    AND at.status != 'failed'
    AND (at.next_scheduled_at IS NULL OR at.next_scheduled_at <= NOW())
  LIMIT 1;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- SAMPLE TOOL REGISTRY DATA
-- ============================================

INSERT INTO tool_registry (toolkit, tool_slug, tool_name, description, input_schema, output_schema, capability_tags, category, rate_limit_per_minute)
VALUES
  ('web', 'FETCH_NEWS', 'Fetch News', 'Fetch latest news from multiple sources',
   '{"type": "object", "properties": {"query": {"type": "string"}, "limit": {"type": "number"}}}',
   '{"type": "object", "properties": {"articles": {"type": "array"}}}',
   ARRAY['fetch', 'news', 'web'], 'data_fetch', 60)
  ON CONFLICT DO NOTHING;

INSERT INTO tool_registry (toolkit, tool_slug, tool_name, description, input_schema, capability_tags, category, rate_limit_per_minute)
VALUES
  ('github', 'GITHUB_CREATE_AN_ISSUE', 'Create GitHub Issue', 'Create a new issue in a GitHub repository',
   '{"type": "object", "properties": {"owner": {"type": "string"}, "repo": {"type": "string"}, "title": {"type": "string"}}}',
   ARRAY['create', 'github'], 'task_creation', 120)
  ON CONFLICT DO NOTHING;

INSERT INTO tool_registry (toolkit, tool_slug, tool_name, description, input_schema, capability_tags, category, rate_limit_per_minute)
VALUES
  ('email', 'SEND_EMAIL', 'Send Email', 'Send an email',
   '{"type": "object", "properties": {"to": {"type": "string"}, "subject": {"type": "string"}}}',
   ARRAY['send', 'email', 'communication'], 'communication', 60)
  ON CONFLICT DO NOTHING;

-- ============================================
-- VIEWS
-- ============================================

CREATE OR REPLACE VIEW active_ai_tasks AS
SELECT *
FROM ai_tasks
WHERE status IN ('pending', 'planning', 'executing')
ORDER BY created_at DESC;

CREATE OR REPLACE VIEW failed_ai_tasks AS
SELECT id, user_id, title, description, error_message, error_recovery_attempts, completed_at
FROM ai_tasks
WHERE status = 'failed'
  AND error_recovery_attempts < 3
ORDER BY completed_at DESC;

CREATE OR REPLACE VIEW task_execution_metrics AS
SELECT
  user_id,
  COUNT(*) as total_tasks,
  COUNT(*) FILTER (WHERE status = 'completed') as successful_tasks,
  COUNT(*) FILTER (WHERE status = 'failed') as failed_tasks,
  AVG(total_duration_ms) as avg_duration_ms,
  MAX(completed_at) as last_execution
FROM ai_tasks
WHERE completed_at IS NOT NULL
GROUP BY user_id;
