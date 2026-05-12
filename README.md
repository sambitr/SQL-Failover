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

To be updated....

