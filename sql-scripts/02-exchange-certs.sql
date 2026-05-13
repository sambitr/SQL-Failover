-- ============================================================
-- STEP 2: Exchange certificates between nodes
-- 
-- After Step 1, copy certificates between pods:
--   kubectl cp sql/sqlserver-primary-0:/var/opt/mssql/ag_cert_primary.cer ./ag_cert_primary.cer
--   kubectl cp sql/sqlserver-secondary-0:/var/opt/mssql/ag_cert_secondary.cer ./ag_cert_secondary.cer
--   kubectl cp ./ag_cert_secondary.cer sql/sqlserver-primary-0:/var/opt/mssql/ag_cert_secondary.cer
--   kubectl cp ./ag_cert_primary.cer sql/sqlserver-secondary-0:/var/opt/mssql/ag_cert_primary.cer
-- ============================================================

-- === Run on PRIMARY ===
-- Create a login and user for the secondary to authenticate
CREATE LOGIN secondary_login WITH PASSWORD = 'S3condary!Login';
CREATE USER secondary_user FOR LOGIN secondary_login;

-- Load the secondary's certificate and grant it connect permission
CREATE CERTIFICATE ag_cert_secondary
    AUTHORIZATION secondary_user
    FROM FILE = '/var/opt/mssql/ag_cert_secondary.cer';

GRANT CONNECT ON ENDPOINT::AG_Endpoint TO secondary_login;
GO

-- === Run on SECONDARY ===
-- CREATE LOGIN primary_login WITH PASSWORD = 'Pr1mary!Login';
-- CREATE USER primary_user FOR LOGIN primary_login;
--
-- CREATE CERTIFICATE ag_cert_primary
--     AUTHORIZATION primary_user
--     FROM FILE = '/var/opt/mssql/ag_cert_primary.cer';
--
-- GRANT CONNECT ON ENDPOINT::AG_Endpoint TO primary_login;
-- GO
