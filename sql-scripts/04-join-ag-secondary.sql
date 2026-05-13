-- ============================================================
-- STEP 4: Join the AG on the SECONDARY
-- This tells the secondary: "I'm joining the K8sAG group, and I allow the primary to automatically seed (copy) the TestDB database to me."
-- ============================================================

-- Run on SECONDARY
ALTER AVAILABILITY GROUP [K8sAG] JOIN WITH (CLUSTER_TYPE = NONE);
GO

-- Allow automatic seeding so the database is copied from primary
ALTER AVAILABILITY GROUP [K8sAG] GRANT CREATE ANY DATABASE;
GO
