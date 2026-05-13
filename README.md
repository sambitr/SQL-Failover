# SQL Server Always On Availability Group on Kubernetes

A complete guide to deploying a **SQL Server 2025 Always On Availability Group (AG)** on Kubernetes using Docker Desktop. This document covers every design decision, deployment step, issue encountered, and resolution — written so that anyone (even without deep SQL/K8s experience) can follow along.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Why These Technology Choices?](#why-these-technology-choices)
3. [Understanding the YAML Manifests](#understanding-the-yaml-manifests)
4. [Deployment Issues We Faced & How We Solved Them](#deployment-issues-we-faced--how-we-solved-them)
5. [Deployment Steps](#deployment-steps)
6. [SSMS Connection](#ssms-connection)
7. [SQL Script 01 — Setup Endpoints](#sql-script-01--setup-endpoints)
8. [SQL Script 02 — Exchange Certificates](#sql-script-02--exchange-certificates)
9. [SQL Script 03 — Create AG on Primary](#sql-script-03--create-ag-on-primary)
10. [SQL Script 04 — Join AG on Secondary](#sql-script-04--join-ag-on-secondary)
11. [SQL Script 05 — Verify & Test Failover](#sql-script-05--verify--test-failover)
12. [Failover & Fail-Back Procedure](#failover--fail-back-procedure)
13. [Verification Queries](#verification-queries)
14. [Clean Redeployment](#clean-redeployment)
15. [Troubleshooting Guide](#troubleshooting-guide)
16. [Summary](#summary)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Docker Desktop K8s                        │
│                     Namespace: sql                           │
│                                                             │
│  ┌─────────────────────┐     ┌─────────────────────┐       │
│  │ sqlserver-primary-0  │     │ sqlserver-secondary-0│       │
│  │                     │     │                     │       │
│  │  SQL Server 2025    │◄───►│  SQL Server 2025    │       │
│  │  Port 1433 (SQL)    │5022 │  Port 1433 (SQL)    │       │
│  │  Port 5022 (AG)     │     │  Port 5022 (AG)     │       │
│  │                     │     │                     │       │
│  │  PVC ──► /var/opt/  │     │  PVC ──► /var/opt/  │       │
│  │          mssql      │     │          mssql      │       │
│  └─────────────────────┘     └─────────────────────┘       │
│         │                              │                    │
│    NodePort 31433                 NodePort 32433             │
│    NodePort 31522                 NodePort 32522             │
└─────────────────────────────────────────────────────────────┘
         │                              │
    SSMS: localhost,31433          SSMS: localhost,32433
```

---

## Why These Technology Choices?

### Why SQL Server 2025?
- It's the latest version with improved Always On AG support on Linux/containers.
- It runs as **non-root by default** (user `mssql`, UID 10001) — a security best practice.
- It supports `CLUSTER_TYPE = NONE`, meaning you don't need Windows Failover Clustering (WSFC) or Pacemaker — perfect for Kubernetes.

### Why StatefulSet (not Deployment)?
- **Stable pod names**: A StatefulSet gives each pod a predictable name like `sqlserver-primary-0`. This matters because SQL Server's `@@SERVERNAME` uses the pod hostname, and the AG replica names must match exactly.
- **Stable storage**: StatefulSets maintain a sticky relationship between a pod and its PersistentVolumeClaim. If the pod restarts, it gets the **same** storage back — your databases survive.
- **Ordered startup**: StatefulSets start pods one at a time in order, which helps when you need predictable initialization.
- **A Deployment would be wrong**: Deployments create pods with random names (like `sqlserver-abc123`), and if a pod restarts, it could get a different PVC. Your entire database would be gone.

### Why Docker Desktop?
- Simple local Kubernetes environment for development/testing.
- `localhost` maps directly to node ports — no extra networking needed.
- Sufficient resources for running two SQL Server instances.

---

## Understanding the YAML Manifests

### `namespace.yaml` — Isolation
Creates a dedicated `sql` namespace. This keeps all SQL Server resources separated from other workloads, making cleanup and management easier.

### `secret.yaml` — SA Password
Stores the SQL Server `sa` password (`K8sAdmin1234!`) as a Kubernetes Secret. Using `stringData` means you write it in plain text in the YAML, but K8s stores it base64-encoded. The password must meet SQL Server complexity requirements: 8+ characters, with uppercase, lowercase, digit, and special character.

### `primary.yaml` / `secondary.yaml` — The Main Manifests

Each file contains 5 Kubernetes resources:

#### 1. PersistentVolume (PV)
```yaml
hostPath:
  path: /var/lib/sqldata/sqlserver-primary
```
- **What**: Reserves a directory on the node's filesystem for SQL Server data.
- **Why `/var/lib/sqldata/`**: This path is on the root filesystem of the Docker Desktop VM, which has plenty of space and **persists across Docker Desktop restarts** (unlike `/tmp`).
- **`persistentVolumeReclaimPolicy: Retain`**: When the PVC is deleted, the data stays on disk. This prevents accidental data loss.

#### 2. PersistentVolumeClaim (PVC)
- **What**: A "request" for storage that binds to the PV above.
- **Why**: Pods don't talk to PVs directly — they go through PVCs. This abstraction lets you swap storage backends without changing the pod spec.

#### 3. ConfigMap
```yaml
data:
  ACCEPT_EULA: "Y"              # Required to start SQL Server
  MSSQL_PID: "Developer"        # Free Developer edition (full features)
  MSSQL_ENABLE_HADR: "1"        # Enables Always On AG engine
  MSSQL_AGENT_ENABLED: "true"   # Enables SQL Agent (useful for AG jobs)
```
- **Why ConfigMap**: Non-sensitive configuration is separated from secrets. If you need to change the edition or toggle HADR, you edit the ConfigMap without touching the deployment.

#### 4. StatefulSet (the core)

Key configuration explained:

| Config | Value | Why |
|--------|-------|-----|
| `hostname` | `sql-primary` / `sql-secondary` | Gives the pod a stable hostname for DNS |
| `fsGroup: 10001` | GID for `mssql` user | Ensures files on mounted volumes are group-owned by `mssql` |
| `initContainer (fix-permissions)` | `chown -R 10001:10001` | Runs as root to fix PV directory ownership before SQL Server starts |
| Port `1433` | SQL client port | Where SSMS/apps connect |
| Port `5022` | AG endpoint port | Where the two replicas communicate for replication |
| Memory request `2Gi` | SQL Server minimum | SQL Server won't start with less than 2GB |
| Memory limit `4Gi` | Reasonable cap | Prevents SQL Server from consuming all node memory |

**emptyDir volumes** — three critical mounts:

| Mount Path | Why |
|------------|-----|
| `/.system` | SQL Server 2025 needs a writable `/.system` at the root filesystem. The non-root `mssql` user can't create it, so we mount a writable `emptyDir`. |
| `/log` | Same issue — SQL Server needs a writable `/log` directory at root level. |
| `/tmp` | General temp directory that must be writable. |

These `emptyDir` volumes are ephemeral (cleared on pod restart), but that's fine — they only hold temporary runtime files, not your databases.

#### 5. Services (two per instance)

**Headless Service** (`clusterIP: None`):
- Required by StatefulSets for stable internal DNS.
- Creates DNS entries like `sqlserver-primary-service.sql.svc.cluster.local`.
- Used by the AG endpoints to find each other within the cluster.

**NodePort Service**:
- Exposes SQL Server to your host machine for SSMS access.
- Primary: `31433` (SQL), `31522` (AG)
- Secondary: `32433` (SQL), `32522` (AG)

---

## Deployment Issues We Faced & How We Solved Them

### Issue 1: `/.system could not be created — Permission denied`
- **Cause**: SQL Server 2025 runs as non-root user `mssql` (UID 10001) by default. It needs to create `/.system` at the root of the filesystem, but a non-root user can't write to `/`.
- **Fix**: Added an `emptyDir` volume mounted at `/.system`. With `fsGroup: 10001`, the mount is writable by the `mssql` user.
- **Lesson**: SQL Server 2025's non-root mode requires writable directories at `/.system`, `/log`, and `/tmp`.

### Issue 2: `PAL initialization failed. Error: 101` when running as root
- **Cause**: We tried setting `runAsUser: 0` (root) to bypass the permission issue. But SQL Server 2025 explicitly expects to run as the `mssql` user and fails PAL (Platform Abstraction Layer) initialization when run as root.
- **Fix**: Reverted to non-root and used `emptyDir` mounts instead.
- **Lesson**: Don't force SQL Server 2025 to run as root. Use `emptyDir` volumes for the directories it needs.

### Issue 3: `No space left on device`
- **Cause**: The hostPath was on `/mnt/data`, backed by a tiny 128MB virtual disk (`/dev/sdd`). SQL Server needs at least ~500MB just to initialize system databases, and crash dumps filled the remaining space.
- **Fix**: Changed the hostPath to `/var/lib/sqldata/` on the root filesystem, which has many GBs available.
- **Lesson**: Always check `df -h` on your node to ensure the storage path has sufficient space. SQL Server needs at minimum 500MB for initialization, plus space for your databases.

### Issue 4: `BootstrapSystemDataDirectories() failure` / corrupt system files
- **Cause**: Repeated crash loops left partially-written system database files on the PV. SQL Server couldn't reuse them.
- **Fix**: Scaled down the StatefulSet, ran a cleanup pod to `rm -rf` the data directory, then redeployed.
- **Lesson**: If SQL Server fails during first initialization, you must wipe the data directory before retrying. Partial initialization files are not recoverable.

### Issue 5: Extremely slow SSMS connectivity
- **Cause**: The 128MB disk was nearly full, causing severe I/O bottleneck. Every SQL Server operation (tempdb writes, catalog queries, login handshake) was slow.
- **Fix**: Moving to `/var/lib/sqldata/` on the root filesystem (backed by the host's SSD/NVMe) made connections instant.
- **Lesson**: Disk I/O performance directly impacts SQL Server responsiveness.

### Issue 6: `hadr cluster type` config option doesn't exist
- **Cause**: The `sp_configure 'hadr cluster type'` option was removed in SQL Server 2025. It was an older Linux-specific setting.
- **Fix**: Removed that line from script 01. The cluster type is now set per-AG in the `CREATE AVAILABILITY GROUP` statement (script 03) with `CLUSTER_TYPE = NONE`.
- **Lesson**: SQL Server 2025 changed how cluster type is configured. It's now at the AG level, not the instance level.

### Issue 7: `None of the specified replicas maps to this instance`
- **Cause**: The replica names in the `CREATE AVAILABILITY GROUP` statement used the hostnames we set in the StatefulSet (`sql-primary`, `sql-secondary`), but `@@SERVERNAME` returned the pod names (`sqlserver-primary-0`, `sqlserver-secondary-0`).
- **Fix**: Updated the replica names to match `@@SERVERNAME` output.
- **Lesson**: Always check `SELECT @@SERVERNAME` and use that exact value as the replica name. In Kubernetes StatefulSets, `@@SERVERNAME` typically returns the pod name.

### Issue 8: `SUSPEND_FROM_PARTNER` after failover
- **Cause**: After a manual failover, the database on the old primary (now secondary) was suspended — data movement was paused.
- **Fix**: Ran `ALTER DATABASE [TestDB] SET HADR RESUME;` on both instances.
- **Lesson**: After every `FORCE_FAILOVER_ALLOW_DATA_LOSS`, you must resume data movement on both replicas.

---

## Deployment Steps

### Prerequisites
- Docker Desktop with Kubernetes enabled
- `kubectl` configured and pointing to Docker Desktop cluster
- SSMS (SQL Server Management Studio) installed for running SQL scripts

### Step-by-Step

```bash
# 1. Create namespace
kubectl apply -f namespace.yaml

# 2. Create the shared secret
kubectl apply -f secret.yaml

# 3. Create host directories on the node for persistent storage
kubectl run setup --rm -it --restart=Never --image=busybox \
  --command -- sh -c "mkdir -p /var/lib/sqldata/sqlserver-primary /var/lib/sqldata/sqlserver-secondary && echo READY"

# 4. Deploy primary and secondary
kubectl apply -f primary.yaml -f secondary.yaml

# 5. Wait for pods to be ready (SQL Server takes ~30-60s to start)
kubectl get pods -n sql -w
# Wait until both show 1/1 Running, then press Ctrl+C
```

---

## SSMS Connection

Since we use NodePort services on Docker Desktop, `localhost` maps directly to the node.

| Instance | Server Name | Auth | Login | Password |
|----------|------------|------|-------|----------|
| Primary | `localhost,31433` | SQL Server Auth | `sa` | `K8sAdmin1234!` |
| Secondary | `localhost,32433` | SQL Server Auth | `sa` | `K8sAdmin1234!` |

### Port Map
| Service | Port | Purpose |
|---------|------|---------|
| Primary SQL | 31433 | T-SQL / SSMS queries |
| Primary AG Endpoint | 31522 | AG replication traffic |
| Secondary SQL | 32433 | T-SQL / SSMS queries |
| Secondary AG Endpoint | 32522 | AG replication traffic |

---

## SQL Script 01 — Setup Endpoints

**File**: `sql-scripts/01-setup-endpoints.sql`
**Run on**: BOTH primary AND secondary
**Purpose**: Prepare each SQL Server instance to communicate securely with the other.

### What it does (in plain English)

Think of this as **setting up a secure private phone line** between two offices:

1. **Enable advanced options** (`sp_configure`) — Flips on the admin panel so we can access deeper settings. Routine housekeeping.

2. **Create a Master Key** — Each SQL Server gets a "safe" (master key) in its `master` database. This safe protects the certificate's private key. Without it, you can't create certificates.

3. **Create a Certificate (`ag_cert`)** — Each server gets its own "ID card." When the two servers talk later, they show their ID cards to prove their identity. This is how they trust each other — no impersonation possible.

4. **Create an Endpoint (`AG_Endpoint` on port 5022)** — Installs a dedicated phone line on port 5022, separate from the regular client port (1433). This private line is exclusively for AG replication traffic. It's configured with:
   - Certificate authentication (only callers with valid ID cards can connect)
   - AES encryption (all replication data is encrypted in transit)

5. **Backup the certificate to a file** — Exports a photocopy of the ID card to a `.cer` file. This will be copied to the other server in step 02.

### Issues you may face

| Issue | Cause | Fix |
|-------|-------|-----|
| `hadr cluster type does not exist` | SQL Server 2025 removed this config | Already removed from script; cluster type is set in script 03 |
| `master key already exists` | Script was run before | Skip this step or `DROP MASTER KEY` first |
| `certificate already exists` | Script was run before | `DROP CERTIFICATE ag_cert` first |
| `endpoint already exists` | Script was run before | `DROP ENDPOINT [AG_Endpoint]` first |
| `cannot write cert file` | File already exists from a previous run | Delete via: `kubectl exec -n sql <pod> -c sqlserver -- rm -f /var/opt/mssql/ag_cert_*.cer` |

### How to verify

```sql
-- Check master key
SELECT * FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##';

-- Check certificate
SELECT name, subject, expiry_date FROM sys.certificates WHERE name = 'ag_cert';

-- Check endpoint
SELECT name, state_desc, port FROM sys.tcp_endpoints WHERE name = 'AG_Endpoint';
```

```bash
# Check cert file exists
kubectl exec -n sql sqlserver-primary-0 -c sqlserver -- ls -la /var/opt/mssql/ag_cert_primary.cer
kubectl exec -n sql sqlserver-secondary-0 -c sqlserver -- ls -la /var/opt/mssql/ag_cert_secondary.cer
```

> **Note**: On the secondary, the cert backup line is **commented out** in the script. You must uncomment and run: `BACKUP CERTIFICATE ag_cert TO FILE = '/var/opt/mssql/ag_cert_secondary.cer';`

---

## SQL Script 02 — Exchange Certificates

**File**: `sql-scripts/02-exchange-certs.sql`
**Run on**: Different SQL on each server (see below)
**Purpose**: Each server learns to recognize the other's ID card (certificate) and allows it to connect.

### What it does (in plain English)

Remember, each server now has its own ID card. But they don't know what each other's ID looks like. This step is like **mailing a photocopy of your ID card to the other office, and having them file it in their visitor log**.

### Pre-requisite: Copy cert files between pods

Before running any SQL, you must physically copy the certificate files between the pods:

```bash
# Download both certs to your local machine
kubectl cp sql/sqlserver-primary-0:/var/opt/mssql/ag_cert_primary.cer ./ag_cert_primary.cer -c sqlserver
kubectl cp sql/sqlserver-secondary-0:/var/opt/mssql/ag_cert_secondary.cer ./ag_cert_secondary.cer -c sqlserver

# Upload each cert to the other pod
kubectl cp ./ag_cert_secondary.cer sql/sqlserver-primary-0:/var/opt/mssql/ag_cert_secondary.cer -c sqlserver
kubectl cp ./ag_cert_primary.cer sql/sqlserver-secondary-0:/var/opt/mssql/ag_cert_primary.cer -c sqlserver
```

### Then run SQL

**On PRIMARY** (`localhost,31433`):
```sql
CREATE LOGIN secondary_login WITH PASSWORD = 'S3condary!Login';
CREATE USER secondary_user FOR LOGIN secondary_login;

CREATE CERTIFICATE ag_cert_secondary
    AUTHORIZATION secondary_user
    FROM FILE = '/var/opt/mssql/ag_cert_secondary.cer';

GRANT CONNECT ON ENDPOINT::AG_Endpoint TO secondary_login;
GO
```

**On SECONDARY** (`localhost,32433`):
```sql
CREATE LOGIN primary_login WITH PASSWORD = 'Pr1mary!Login';
CREATE USER primary_user FOR LOGIN primary_login;

CREATE CERTIFICATE ag_cert_primary
    AUTHORIZATION primary_user
    FROM FILE = '/var/opt/mssql/ag_cert_primary.cer';

GRANT CONNECT ON ENDPOINT::AG_Endpoint TO primary_login;
GO
```

### Step by step:
1. **Create a login + user** — Like creating a "visitor badge" for the other server. On primary, we create `secondary_login`; on secondary, `primary_login`.
2. **Import the other server's certificate** — "I now know what the other server's ID card looks like."
3. **Grant CONNECT on endpoint** — "I allow this visitor badge holder to use my private phone line (port 5022)."

### Issues you may face

| Issue | Cause | Fix |
|-------|-------|-----|
| `certificate file not found` | Forgot to run the `kubectl cp` commands | Run the copy commands above first |
| `login already exists` | Script was run before | `DROP LOGIN secondary_login` (or `primary_login`) first |

### How to verify

```sql
-- Should show 2 certs: ag_cert (own) + the imported one
SELECT name, subject FROM sys.certificates;

-- Should show the login has CONNECT on the endpoint
SELECT sp.name AS login_name, p.permission_name
FROM sys.server_permissions p
JOIN sys.server_principals sp ON p.grantee_principal_id = sp.principal_id
JOIN sys.endpoints ep ON p.major_id = ep.endpoint_id
WHERE ep.name = 'AG_Endpoint';
```

---

## SQL Script 03 — Create AG on Primary

**File**: `sql-scripts/03-create-ag-primary.sql`
**Run on**: PRIMARY only (`localhost,31433`)
**Purpose**: Create a test database and the Availability Group itself.

### What it does (in plain English)

This is the **main event** — after all the preparation, we finally create the Availability Group.

1. **Create `TestDB`** — The database we want to replicate. In a real scenario, this would be your application database.

2. **Set FULL recovery model** — AG requires this. It means every single transaction is logged — this is what allows the secondary to replay every change the primary makes. Think of it as keeping a complete diary of every change, not just summaries.

3. **Take a full backup** — AG needs a "snapshot" of the database as a starting point before it can begin tracking changes. Like saying "here's the baseline, now watch for everything after this."

4. **Create the Availability Group (`K8sAG`)** — The big one. This defines:
   - **`CLUSTER_TYPE = NONE`** — No Windows cluster or Pacemaker. We manage failover manually. Perfect for Kubernetes where we don't have traditional clustering.
   - **`SYNCHRONOUS_COMMIT`** — The primary waits for the secondary to confirm receipt of each transaction before telling the client "your write is committed." This means **zero data loss** — if the primary dies, the secondary has everything.
   - **`FAILOVER_MODE = MANUAL`** — You decide when to failover. It won't happen automatically. In production, you might pair this with an external health monitor.
   - **`SEEDING_MODE = AUTOMATIC`** — SQL Server automatically copies the entire database from primary to secondary. No manual backup-restore dance needed.
   - **`SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)`** — You can run read queries on the secondary (read-scale). Useful for offloading reporting queries.

### Critical note on replica names

The replica names must match `@@SERVERNAME` exactly. In our case:
```sql
SELECT @@SERVERNAME;
-- Returns: sqlserver-primary-0  (not sql-primary)
```
The StatefulSet pod name overrides the `hostname` we set. Always check `@@SERVERNAME` first.

### Issues you may face

| Issue | Cause | Fix |
|-------|-------|-----|
| `None of the specified replicas maps to this instance` | Replica name doesn't match `@@SERVERNAME` | Run `SELECT @@SERVERNAME` and use that exact value |
| `Database cannot be added — already joined to another AG` | AG was partially created from a previous attempt | `DROP AVAILABILITY GROUP [K8sAG]` then recreate |
| `Database already exists` | TestDB already exists from a previous run | Skip the `CREATE DATABASE` line, or `DROP DATABASE TestDB` first |

### How to verify

```sql
-- Check AG
SELECT name, cluster_type_desc FROM sys.availability_groups;

-- Check replicas
SELECT replica_server_name, endpoint_url, availability_mode_desc, 
       failover_mode_desc, seeding_mode_desc
FROM sys.availability_replicas;

-- Check database sync status
SELECT ar.replica_server_name, drs.synchronization_state_desc, 
       drs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id;
```

---

## SQL Script 04 — Join AG on Secondary

**File**: `sql-scripts/04-join-ag-secondary.sql`
**Run on**: SECONDARY only (`localhost,32433`)
**Purpose**: The secondary says "I want to join the group" and allows automatic seeding.

### What it does (in plain English)

The primary has already set up the AG and defined both replicas. But the secondary needs to **accept the invitation**. This script does two things:

1. **`ALTER AVAILABILITY GROUP [K8sAG] JOIN`** — "I'm joining the K8sAG group." The secondary connects to the primary over port 5022 using the certificates exchanged in step 02.

2. **`GRANT CREATE ANY DATABASE`** — "I allow the primary to automatically create databases on me." This is the permission that enables automatic seeding. Once granted, the primary streams the entire `TestDB` to the secondary — no manual backup/restore needed.

### The magic of automatic seeding

After running this script, `TestDB` **appears on the secondary automatically**. You never ran `CREATE DATABASE` on the secondary. SQL Server handled it:
- Primary streams the database over port 5022
- Secondary receives it and begins applying all subsequent transactions in real-time
- Within seconds, both databases are in sync

### Issues you may face

| Issue | Cause | Fix |
|-------|-------|-----|
| `AG not found` | AG doesn't exist on primary, or secondary can't reach primary over 5022 | Verify AG exists on primary; check endpoint connectivity |
| `TestDB doesn't appear on secondary` | Seeding failed | Check `sys.dm_hadr_automatic_seeding` on primary for errors |

### How to verify

On the **secondary**:
```sql
-- TestDB should appear as ONLINE
SELECT name, state_desc FROM sys.databases WHERE name = 'TestDB';
```

On **either** instance:
```sql
-- Both should show SYNCHRONIZED + HEALTHY
SELECT ar.replica_server_name, drs.synchronization_state_desc, 
       drs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id;
```

---

## SQL Script 05 — Verify & Test Failover

**File**: `sql-scripts/05-verify-and-failover.sql`
**Run on**: Either instance (health check) / Secondary (failover)
**Purpose**: Confirm everything is healthy, then test a manual failover.

### What it does (in plain English)

**Health check query** — Gives you a full dashboard:
- Which server is PRIMARY, which is SECONDARY
- Are they CONNECTED?
- Is the sync HEALTHY?
- How big is the log send queue (data waiting to be sent)?
- How big is the redo queue (data waiting to be applied)?

If both queues are `0`, the secondary is perfectly caught up.

**Failover commands** (commented out, run manually):
- `FORCE_FAILOVER_ALLOW_DATA_LOSS` — Promotes the secondary to primary
- `SET (ROLE = SECONDARY)` — Demotes the old primary to secondary

### Issues you may face

| Issue | Cause | Fix |
|-------|-------|-----|
| `database_name` column not found | SQL Server 2025 schema difference | Use `DB_NAME(drs.database_id)` instead |
| `NOT_HEALTHY` after failover | Data movement suspended | Run `ALTER DATABASE [TestDB] SET HADR RESUME;` on both instances |
| `SUSPEND_FROM_PARTNER` | Partner hasn't resumed data movement | Resume on BOTH instances (see failover procedure below) |

---

## Failover & Fail-Back Procedure

### Failover (Primary → Secondary)

**Step 1** — On the **SECONDARY** you want to promote (`localhost,32433`):
```sql
ALTER AVAILABILITY GROUP [K8sAG] FORCE_FAILOVER_ALLOW_DATA_LOSS;
GO
```

**Step 2** — On the **old PRIMARY** (`localhost,31433`):
```sql
ALTER AVAILABILITY GROUP [K8sAG] SET (ROLE = SECONDARY);
GO
```

**Step 3** — Resume data movement on **BOTH**:
```sql
ALTER DATABASE [TestDB] SET HADR RESUME;
GO
```

**Step 4** — Verify:
```sql
SELECT ar.replica_server_name, ars.role_desc, ars.synchronization_health_desc
FROM sys.availability_replicas ar
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id;
```

### Fail-Back (Restore Original Config)

Repeat the exact same procedure, but swap the servers:

1. Run `FORCE_FAILOVER_ALLOW_DATA_LOSS` on `localhost,31433` (current secondary)
2. Run `SET (ROLE = SECONDARY)` on `localhost,32433` (current primary)
3. Resume on both
4. Verify

> **Important**: Always run `ALTER DATABASE [TestDB] SET HADR RESUME;` on BOTH instances after every failover. Without this, the replica stays in `NOT_HEALTHY` / `SUSPEND_FROM_PARTNER` state.

---

## Verification Queries

### Quick health check (run on either instance)
```sql
SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc, 
       ars.synchronization_health_desc
FROM sys.availability_replicas ar
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id;
```

### Detailed dashboard
```sql
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    ars.role_desc,
    ars.connected_state_desc,
    ars.synchronization_health_desc,
    drs.synchronization_state_desc,
    drs.log_send_queue_size,
    drs.redo_queue_size
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states drs ON ar.replica_id = drs.replica_id
ORDER BY ar.replica_server_name;
```

### Check all certificates
```sql
SELECT name, subject, expiry_date FROM sys.certificates;
```

### Check endpoint status
```sql
SELECT name, state_desc, port FROM sys.tcp_endpoints WHERE type_desc = 'DATABASE_MIRRORING';
```

---

## Clean Redeployment

If pods are stuck in `CrashLoopBackOff` or `Error` and you need a fresh start:

```bash
# 1. Delete StatefulSets, PVCs, and PVs
kubectl delete statefulset sqlserver-primary sqlserver-secondary -n sql
kubectl delete pvc sqlserver-primary-pvc sqlserver-secondary-pvc -n sql
kubectl delete pv sqlserver-primary-pv sqlserver-secondary-pv

# 2. Wipe data on the node
kubectl run cleanup --rm -it --restart=Never --image=busybox \
  --command -- sh -c "rm -rf /var/lib/sqldata/sqlserver-primary/* /var/lib/sqldata/sqlserver-secondary/* && echo CLEANED"

# 3. Reapply everything
kubectl apply -f namespace.yaml
kubectl apply -f secret.yaml
kubectl run setup --rm -it --restart=Never --image=busybox \
  --command -- sh -c "mkdir -p /var/lib/sqldata/sqlserver-primary /var/lib/sqldata/sqlserver-secondary && echo READY"
kubectl apply -f primary.yaml -f secondary.yaml

# 4. Wait for pods
kubectl get pods -n sql -w
```

> **Warning**: Clean redeployment wipes all databases. You'll need to re-run all 5 SQL scripts.

---

## Troubleshooting Guide

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Pod in `CrashLoopBackOff` | Check `kubectl logs <pod> -n sql` | See specific error sections above |
| `Permission denied` on `/.system`, `/log`, or `/tmp` | Missing `emptyDir` mounts | Ensure all three `emptyDir` volumes are in the StatefulSet |
| `No space left on device` | hostPath disk is full | Clean data directory or move hostPath to larger filesystem |
| `PAL initialization failed. Error: 101` | Running as root (`runAsUser: 0`) | Remove `runAsUser: 0`; SQL Server 2025 must run as `mssql` |
| Slow SSMS connections | Storage I/O bottleneck | Move hostPath to SSD-backed filesystem |
| `hadr cluster type does not exist` | SQL Server 2025 removed this option | Remove from script; set in `CREATE AVAILABILITY GROUP` |
| `replica doesn't map to this instance` | Replica name ≠ `@@SERVERNAME` | Check `SELECT @@SERVERNAME` and use exact value |
| `NOT_HEALTHY` after failover | Data movement suspended | `ALTER DATABASE [TestDB] SET HADR RESUME;` on both |
| Init container fails | Image pull issue | Ensure `busybox` image is available; try `imagePullPolicy: IfNotPresent` |

---

## Summary

We built a **SQL Server 2025 Always On Availability Group** on Kubernetes (Docker Desktop) with:

- **Two SQL Server instances** running as StatefulSets in a dedicated `sql` namespace
- **Persistent storage** at `/var/lib/sqldata/` that survives pod restarts AND Docker Desktop restarts
- **Certificate-based authentication** for secure AG communication over port 5022
- **Synchronous replication** with zero data loss — every transaction is confirmed by both replicas
- **Manual failover** tested in both directions (primary→secondary and back)
- **Automatic seeding** — databases replicate to the secondary without manual backup/restore

### Key lessons learned:
1. **SQL Server 2025 is non-root** — needs `emptyDir` mounts at `/.system`, `/log`, `/tmp` and an initContainer to fix PV ownership
2. **Don't run SQL Server 2025 as root** — PAL initialization fails
3. **Storage matters** — always verify your hostPath has sufficient space and good I/O
4. **`@@SERVERNAME` is king** — AG replica names must match exactly
5. **Resume after failover** — always run `HADR RESUME` on both replicas after any failover
6. **StatefulSet is mandatory** — Deployments don't provide the stable identity and storage that SQL Server needs
