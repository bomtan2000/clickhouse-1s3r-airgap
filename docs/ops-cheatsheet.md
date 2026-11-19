# Ops cheat sheet

Commands I keep reaching for on this cluster. Table names follow `ddl_events.sql`.

## Cluster and replicas

```sql
-- topology as ClickHouse sees it
SELECT cluster, shard_num, replica_num, host_name, port
FROM system.clusters WHERE cluster = 'cluster_1S_3R';

-- replica health: active_replicas must equal total_replicas
SELECT database, table, replica_name, is_readonly, active_replicas, total_replicas,
       queue_size, absolute_delay
FROM system.replicas WHERE table = 'events_local';
```

## Replica stuck or read-only

```bash
# pull everything the replica is missing, wait until done
clickhouse-client -q "SYSTEM SYNC REPLICA db1.events_local;"

# re-init the replica's Keeper session (after Keeper was down, replica stays is_readonly=1)
clickhouse-client -q "SYSTEM RESTART REPLICA db1.events_local;"
```

## Keeper broken on one node

A Keeper node whose Raft log is corrupt can be rebuilt from the other two (quorum 2/3 stays up):

```bash
# on the broken keeper ONLY, with the other two healthy
systemctl stop clickhouse-keeper
rm -rf /APP/clickhouse/keeper/data/log/* /APP/clickhouse/keeper/data/snapshots/*
systemctl start clickhouse-keeper      # re-syncs a snapshot from the leader
echo mntr | nc localhost 9181 | grep -E 'zk_server_state|zk_followers'
```

Never wipe more than one Keeper at a time: losing quorum makes every Replicated table read-only.

## Drop / recreate across the cluster

```sql
DROP TABLE IF EXISTS db1.events ON CLUSTER cluster_1S_3R;          -- Distributed first
DROP TABLE IF EXISTS db1.events_local ON CLUSTER cluster_1S_3R SYNC;
```

## Smoke test through the Distributed table

```sql
INSERT INTO db1.events (id, event_time, event_type) VALUES ('smoke-1', now64(3), 'TEST');
SELECT count() FROM db1.events WHERE id = 'smoke-1';   -- run on every server: same answer
```

## Query cache (dashboards)

```sql
SELECT ... SETTINGS use_query_cache = 1, query_cache_ttl = 60;
-- system tables are not cacheable by default; ignore them instead of failing
SET query_cache_system_table_handling = 'ignore';
```
