-- ============================================================
-- STEP 1: Run on BOTH primary and secondary
-- Connect to each instance and run this block
-- ============================================================

-- Enable AG is already done via MSSQL_ENABLE_HADR=1 env var
-- Cluster type is set in CREATE AVAILABILITY GROUP (step 03)
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;

-- Create master key for endpoint certificate authentication
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'MasterK3y!Str0ng';

-- Create certificate (each node needs its own, then they exchange)
CREATE CERTIFICATE ag_cert
    WITH SUBJECT = 'AG Endpoint Certificate',
    EXPIRY_DATE = '2030-01-01';

-- Create the database mirroring endpoint for AG communication
CREATE ENDPOINT [AG_Endpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (
        ROLE = ALL,
        AUTHENTICATION = CERTIFICATE ag_cert,
        ENCRYPTION = REQUIRED ALGORITHM AES
    );

-- Backup the certificate to share with the other node
-- On PRIMARY, run:
BACKUP CERTIFICATE ag_cert
    TO FILE = '/var/opt/mssql/ag_cert_primary.cer';

-- On SECONDARY, run:
-- BACKUP CERTIFICATE ag_cert
--     TO FILE = '/var/opt/mssql/ag_cert_secondary.cer';

GO

-- After Script 01, each server has:

--  Master Key (the safe)
--  Certificate (its own ID card)
--  Endpoint on port 5022 (the private phone line)
--  Exported .cer file (a photocopy of the ID card, ready to share)