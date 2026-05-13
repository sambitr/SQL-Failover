-- ============================================================
-- STEP 5: Verify AG health & test failover
-- ============================================================

-- Check AG replica state (run on either node)
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    ars.role_desc,
    ars.connected_state_desc,
    ars.synchronization_health_desc,
    adc.database_name,
    drs.synchronization_state_desc,
    drs.log_send_queue_size,
    drs.redo_queue_size
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
LEFT JOIN sys.availability_databases_cluster adc ON ag.group_id = adc.group_id
LEFT JOIN sys.dm_hadr_database_replica_states drs
    ON ar.replica_id = drs.replica_id AND adc.group_database_id = drs.group_database_id
ORDER BY ar.replica_server_name;
GO

-- ============================================================
-- FAILOVER TEST (simulates Azure Failover Group failover)
-- Run on the SECONDARY you want to promote:
-- ============================================================
-- ALTER AVAILABILITY GROUP [K8sAG] FORCE_FAILOVER_ALLOW_DATA_LOSS;
-- GO

-- After failover, the old primary must rejoin as secondary:
-- ALTER AVAILABILITY GROUP [K8sAG] SET (ROLE = SECONDARY);
-- GO
