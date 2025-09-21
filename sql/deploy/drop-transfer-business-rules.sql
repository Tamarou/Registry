-- Deploy registry:drop-transfer-business-rules to pg
-- requires: fix-multi-child-enrollments

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Add drop and transfer tracking fields to enrollments
ALTER TABLE enrollments
  ADD COLUMN IF NOT EXISTS drop_reason text,
  ADD COLUMN IF NOT EXISTS dropped_at timestamp with time zone,
  ADD COLUMN IF NOT EXISTS dropped_by uuid REFERENCES users,
  ADD COLUMN IF NOT EXISTS refund_status text DEFAULT 'none'
    CHECK (refund_status IN ('none', 'pending', 'approved', 'processed', 'denied')),
  ADD COLUMN IF NOT EXISTS refund_amount numeric(10,2),
  ADD COLUMN IF NOT EXISTS transfer_to_session_id uuid REFERENCES sessions,
  ADD COLUMN IF NOT EXISTS transfer_status text DEFAULT 'none'
    CHECK (transfer_status IN ('none', 'requested', 'approved', 'denied', 'completed'));

-- Create drop_requests table for admin approval workflow
CREATE TABLE IF NOT EXISTS drop_requests (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  enrollment_id uuid NOT NULL REFERENCES enrollments,
  requested_by uuid NOT NULL REFERENCES users,
  reason text NOT NULL,
  refund_requested boolean DEFAULT false,
  refund_amount_requested numeric(10,2),
  status text DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'denied')),
  admin_notes text,
  processed_by uuid REFERENCES users,
  processed_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now()
);

-- Create transfer_requests table for admin approval workflow
CREATE TABLE IF NOT EXISTS transfer_requests (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  enrollment_id uuid NOT NULL REFERENCES enrollments,
  target_session_id uuid NOT NULL REFERENCES sessions,
  requested_by uuid NOT NULL REFERENCES users,
  reason text NOT NULL,
  status text DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'denied', 'completed')),
  admin_notes text,
  processed_by uuid REFERENCES users,
  processed_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now()
);

-- Add indexes for performance
CREATE INDEX IF NOT EXISTS idx_drop_requests_enrollment_id ON drop_requests(enrollment_id);
CREATE INDEX IF NOT EXISTS idx_drop_requests_status ON drop_requests(status);
CREATE INDEX IF NOT EXISTS idx_transfer_requests_enrollment_id ON transfer_requests(enrollment_id);
CREATE INDEX IF NOT EXISTS idx_transfer_requests_status ON transfer_requests(status);
CREATE INDEX IF NOT EXISTS idx_enrollments_drop_status ON enrollments(status) WHERE drop_reason IS NOT NULL;

-- Add comments for documentation
COMMENT ON COLUMN enrollments.drop_reason IS 'Reason why enrollment was dropped';
COMMENT ON COLUMN enrollments.dropped_at IS 'Timestamp when enrollment was dropped';
COMMENT ON COLUMN enrollments.dropped_by IS 'User who processed the drop (admin or parent)';
COMMENT ON COLUMN enrollments.refund_status IS 'Status of refund processing for dropped enrollment';
COMMENT ON COLUMN enrollments.refund_amount IS 'Amount refunded for dropped enrollment';
COMMENT ON COLUMN enrollments.transfer_to_session_id IS 'Target session if enrollment was transferred';
COMMENT ON COLUMN enrollments.transfer_status IS 'Status of transfer processing';

COMMENT ON TABLE drop_requests IS 'Requests to drop enrollments that require admin approval';
COMMENT ON TABLE transfer_requests IS 'Requests to transfer enrollments between sessions';

-- Propagate schema changes to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
       -- Add drop/transfer fields to enrollments
       EXECUTE format('ALTER TABLE %I.enrollments
         ADD COLUMN IF NOT EXISTS drop_reason text,
         ADD COLUMN IF NOT EXISTS dropped_at timestamp with time zone,
         ADD COLUMN IF NOT EXISTS dropped_by uuid REFERENCES %I.users,
         ADD COLUMN IF NOT EXISTS refund_status text DEFAULT ''none''
           CHECK (refund_status IN (''none'', ''pending'', ''approved'', ''processed'', ''denied'')),
         ADD COLUMN IF NOT EXISTS refund_amount numeric(10,2),
         ADD COLUMN IF NOT EXISTS transfer_to_session_id uuid REFERENCES %I.sessions,
         ADD COLUMN IF NOT EXISTS transfer_status text DEFAULT ''none''
           CHECK (transfer_status IN (''none'', ''requested'', ''approved'', ''denied'', ''completed''));', s, s, s);

       -- Create drop_requests table
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.drop_requests (
         id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
         enrollment_id uuid NOT NULL REFERENCES %I.enrollments,
         requested_by uuid NOT NULL REFERENCES %I.users,
         reason text NOT NULL,
         refund_requested boolean DEFAULT false,
         refund_amount_requested numeric(10,2),
         status text DEFAULT ''pending''
           CHECK (status IN (''pending'', ''approved'', ''denied'')),
         admin_notes text,
         processed_by uuid REFERENCES %I.users,
         processed_at timestamp with time zone,
         created_at timestamp with time zone DEFAULT now(),
         updated_at timestamp with time zone DEFAULT now()
       );', s, s, s, s);

       -- Create transfer_requests table
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.transfer_requests (
         id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
         enrollment_id uuid NOT NULL REFERENCES %I.enrollments,
         target_session_id uuid NOT NULL REFERENCES %I.sessions,
         requested_by uuid NOT NULL REFERENCES %I.users,
         reason text NOT NULL,
         status text DEFAULT ''pending''
           CHECK (status IN (''pending'', ''approved'', ''denied'', ''completed'')),
         admin_notes text,
         processed_by uuid REFERENCES %I.users,
         processed_at timestamp with time zone,
         created_at timestamp with time zone DEFAULT now(),
         updated_at timestamp with time zone DEFAULT now()
       );', s, s, s, s, s);

       -- Add indexes for performance
       EXECUTE format('CREATE INDEX IF NOT EXISTS idx_drop_requests_enrollment_id ON %I.drop_requests(enrollment_id);', s);
       EXECUTE format('CREATE INDEX IF NOT EXISTS idx_drop_requests_status ON %I.drop_requests(status);', s);
       EXECUTE format('CREATE INDEX IF NOT EXISTS idx_transfer_requests_enrollment_id ON %I.transfer_requests(enrollment_id);', s);
       EXECUTE format('CREATE INDEX IF NOT EXISTS idx_transfer_requests_status ON %I.transfer_requests(status);', s);
       EXECUTE format('CREATE INDEX IF NOT EXISTS idx_enrollments_drop_status ON %I.enrollments(status) WHERE drop_reason IS NOT NULL;', s);
   END LOOP;
END
$$ LANGUAGE plpgsql;

COMMIT;