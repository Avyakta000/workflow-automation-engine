-- ============================================
-- WORKFLOWS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS workflows (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  
  input_schema JSONB NOT NULL DEFAULT '{}',
  output_schema JSONB NOT NULL DEFAULT '{}',
  workflow JSONB NOT NULL DEFAULT '[]',
  defaults_for_required_parameters JSONB DEFAULT '{}',
  
  toolkit_ids TEXT[] DEFAULT ARRAY[]::TEXT[],
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  is_active BOOLEAN DEFAULT TRUE,
  is_public BOOLEAN DEFAULT FALSE,
  
  CONSTRAINT workflow_owner CHECK (user_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_workflows_user_id ON workflows(user_id);
CREATE INDEX IF NOT EXISTS idx_workflows_is_active ON workflows(is_active);

-- ============================================
-- SCHEDULED_WORKFLOWS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS scheduled_workflows (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  
  name TEXT NOT NULL,
  cron_expression TEXT NOT NULL,
  cron_timezone TEXT DEFAULT 'UTC',
  
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'paused', 'disabled')),
  is_enabled BOOLEAN DEFAULT TRUE,
  
  last_run_at TIMESTAMP,
  next_run_at TIMESTAMP,
  total_runs INTEGER DEFAULT 0,
  successful_runs INTEGER DEFAULT 0,
  failed_runs INTEGER DEFAULT 0,
  
  params JSONB DEFAULT '{}',
  
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  created_by UUID REFERENCES auth.users(id),
  
  CONSTRAINT schedule_owner CHECK (user_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_scheduled_workflows_user_id ON scheduled_workflows(user_id);
CREATE INDEX IF NOT EXISTS idx_scheduled_workflows_workflow_id ON scheduled_workflows(workflow_id);
CREATE INDEX IF NOT EXISTS idx_scheduled_workflows_status ON scheduled_workflows(status);
CREATE INDEX IF NOT EXISTS idx_scheduled_workflows_next_run ON scheduled_workflows(next_run_at);

-- ============================================
-- EXECUTION_LOGS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS execution_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  scheduled_workflow_id UUID NOT NULL REFERENCES scheduled_workflows(id) ON DELETE CASCADE,
  workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  
  status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'success', 'failed', 'timeout', 'cancelled')),
  
  input_data JSONB,
  output_data JSONB,
  
  error_message TEXT,
  error_code TEXT,
  error_stack JSONB,
  
  started_at TIMESTAMP DEFAULT NOW(),
  completed_at TIMESTAMP,
  duration_ms INTEGER,
  
  triggered_by TEXT DEFAULT 'scheduler',
  job_id TEXT UNIQUE,
  retry_count INTEGER DEFAULT 0,
  
  created_at TIMESTAMP DEFAULT NOW(),
  
  CONSTRAINT execution_owner CHECK (user_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_execution_logs_scheduled_workflow ON execution_logs(scheduled_workflow_id);
CREATE INDEX IF NOT EXISTS idx_execution_logs_user_id ON execution_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_execution_logs_status ON execution_logs(status);
CREATE INDEX IF NOT EXISTS idx_execution_logs_created_at ON execution_logs(created_at);

-- ============================================
-- WORKFLOW_STEPS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS workflow_steps (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
  
  step_number INTEGER NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  
  toolkit TEXT NOT NULL,
  tool_slug TEXT NOT NULL,
  tool_arguments JSONB NOT NULL DEFAULT '{}',
  
  depends_on_step_id UUID REFERENCES workflow_steps(id),
  run_if_condition JSONB,
  retry_on_failure BOOLEAN DEFAULT TRUE,
  max_retries INTEGER DEFAULT 3,
  timeout_seconds INTEGER DEFAULT 300,
  
  output_mapping JSONB,
  
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  CONSTRAINT valid_step_number CHECK (step_number > 0),
  UNIQUE(workflow_id, step_number)
);

CREATE INDEX IF NOT EXISTS idx_workflow_steps_workflow_id ON workflow_steps(workflow_id);

-- ============================================
-- MCP_CREDENTIALS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS mcp_credentials (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  
  toolkit TEXT NOT NULL,
  credential_name TEXT NOT NULL,
  
  encrypted_credential BYTEA NOT NULL,
  encryption_key_version INTEGER,
  
  is_active BOOLEAN DEFAULT TRUE,
  last_used_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  
  CONSTRAINT credential_owner CHECK (user_id IS NOT NULL),
  UNIQUE(user_id, toolkit, credential_name)
);

CREATE INDEX IF NOT EXISTS idx_mcp_credentials_user_id ON mcp_credentials(user_id);
CREATE INDEX IF NOT EXISTS idx_mcp_credentials_toolkit ON mcp_credentials(toolkit);

-- ============================================
-- WEBHOOK_TRIGGERS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS webhook_triggers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  scheduled_workflow_id UUID NOT NULL REFERENCES scheduled_workflows(id) ON DELETE CASCADE,
  
  webhook_url TEXT NOT NULL UNIQUE,
  webhook_secret TEXT NOT NULL,
  
  allowed_ips TEXT[],
  rate_limit INTEGER DEFAULT 100,
  
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_webhook_triggers_webhook_url ON webhook_triggers(webhook_url);

-- ============================================
-- AUDIT_LOGS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id),
  action TEXT NOT NULL,
  resource_type TEXT,
  resource_id UUID,
  changes JSONB,
  ip_address INET,
  user_agent TEXT,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at);

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

-- Increment successful runs
CREATE OR REPLACE FUNCTION increment_successful_runs(schedule_id UUID)
RETURNS VOID AS $$
BEGIN
  UPDATE scheduled_workflows
  SET
    successful_runs = successful_runs + 1,
    total_runs = total_runs + 1,
    last_run_at = NOW()
  WHERE id = schedule_id;
END;
$$ LANGUAGE plpgsql;

-- Increment failed runs
CREATE OR REPLACE FUNCTION increment_failed_runs(schedule_id UUID)
RETURNS VOID AS $$
BEGIN
  UPDATE scheduled_workflows
  SET
    failed_runs = failed_runs + 1,
    total_runs = total_runs + 1,
    last_run_at = NOW()
  WHERE id = schedule_id;
END;
$$ LANGUAGE plpgsql;
