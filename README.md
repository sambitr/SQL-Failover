# SQL-Failover
I want to carry out the setup that helps setting up Azure SQL failover group, where by through one common SQL DNS server, you can read and write in to primary SQL server and at the same time the data gets replicated immediately to the dedicated secondary SQL server. 

                ┌─────────────────────┐
                │   Application       │
                │ uses stable DNS     │
                └─────────┬───────────┘
                          │
                    db.mycompany.com
                          │
               ┌──────────┴──────────┐
               │                     │
        PRIMARY DATABASE      SECONDARY DATABASE
           Region A               Region B
         (read/write)            (replica)

The important pieces are:

- Primary accepts writes
- Secondary continuously receives changes
- If primary dies:
  - secondary is promoted
  - clients reconnect using same DNS name

## In General what are needed to be done

1. SQL Servers
2. Health monitoring setup to montor the endpoint
3. Automatic failover orchestration
4. Stable DNS endpoint


### Local Kubernetes cluster

I used Docker Desktop to launch a local kubernetes cluster
```
$ kubectl config use-context docker-desktop
Switched to context "docker-desktop".

$ kubectl get nodes
NAME             STATUS   ROLES           AGE     VERSION
docker-desktop   Ready    control-plane   9m10s   v1.34.1

$ kubectl get ns
NAME              STATUS   AGE
default           Active   9m16s
kube-node-lease   Active   9m16s
kube-public       Active   9m16s
kube-system       Active   9m16s

$ k create ns sql
namespace/sql created

UK+skrout@DT-V11APTL1-18 MINGW64 ~/OneDrive 
$ kgns
NAME                STATUS   AGE
default             Active   9m33s
kube-node-lease     Active   9m33s
kube-public         Active   9m33s
kube-system         Active   9m33s
sql                 Active   3s
```
### Use SQL server Image to create SQL server

```
$ docker pull mcr.microsoft.com/mssql/server:2025-latest
2025-latest: Pulling from mssql/server
4eef054c5dbd: Pull complete
901cdc4e17f1: Pull complete
1b62b5413821: Pull complete
Digest: sha256:320daf857745ef0092c6e53e82d0bf81ed6bca2794e6ccbffb72cf6a8d14a441
Status: Downloaded newer image for mcr.microsoft.com/mssql/server:2025-latest
mcr.microsoft.com/mssql/server:2025-latest
```

Use the manifest file to deploy to ```sql``` namespace: 
https://github.com/sambitr/SQL-Failover/blob/main/sql-server.yaml
https://github.com/sambitr/SQL-Failover/blob/main/sql-server-secondary.yaml

```
$ kubectl apply -f sql-server.yaml -n sql
configmap/sqlserver-primary-config created
deployment.apps/sqlserver-primary created
service/sqlserver-primary-service created
service/sqlserver-primary-external created

$ kubectl apply -f sql-server-secondary.yaml -n sql
configmap/sqlserver-secondary-config created
deployment.apps/sqlserver-secondary created
service/sqlserver-secondary-service created
service/sqlserver-secondary-external created

$ kubectl get all -n sql
NAME                                       READY   STATUS    RESTARTS   AGE
pod/sqlserver-primary-5b7856b897-p9x6s     1/1     Running   0          59s
pod/sqlserver-secondary-5677fcd8b9-j5gb4   1/1     Running   0          4s

NAME                                   TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)          AGE
service/sqlserver-primary-external     NodePort    10.110.14.208    <none>        1433:31433/TCP   59s
service/sqlserver-primary-service      ClusterIP   10.96.218.220    <none>        1433/TCP         59s
service/sqlserver-secondary-external   NodePort    10.97.202.4      <none>        1433:32433/TCP   4s
service/sqlserver-secondary-service    ClusterIP   10.101.147.214   <none>        1433/TCP         4s

NAME                                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/sqlserver-primary     1/1     1            1           59s
deployment.apps/sqlserver-secondary   1/1     1            1           4s

NAME                                             DESIRED   CURRENT   READY   AGE
replicaset.apps/sqlserver-primary-5b7856b897     1         1         1       59s
replicaset.apps/sqlserver-secondary-5677fcd8b9   1         1         1       4s
```

To be updated....

