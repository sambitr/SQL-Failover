-- ============================================================
-- STEP 3: Create a test database and the AG (run on PRIMARY)
-- ============================================================

-- Create a test database
CREATE DATABASE TestDB;
GO

-- AG requires FULL recovery model
ALTER DATABASE TestDB SET RECOVERY FULL;
GO

-- Take a full backup (required before adding to AG)
BACKUP DATABASE TestDB TO DISK = '/var/opt/mssql/TestDB.bak';
BACKUP LOG TestDB TO DISK = '/var/opt/mssql/TestDB_log.trn';
GO

-- Create the Availability Group
-- CLUSTER_TYPE = NONE means no Pacemaker or WSFC — manual failover only
-- Use the pod hostnames set in the StatefulSet specs
CREATE AVAILABILITY GROUP [K8sAG]
WITH (CLUSTER_TYPE = NONE)
FOR DATABASE [TestDB]
REPLICA ON
    N'sqlserver-primary-0' WITH (
        ENDPOINT_URL = N'tcp://sqlserver-primary-service.sql.svc.cluster.local:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)   -- enables read-scale on secondary
    ),
    N'sqlserver-secondary-0' WITH (
        ENDPOINT_URL = N'tcp://sqlserver-secondary-service.sql.svc.cluster.local:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)
    );
GO
