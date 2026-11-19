-- Example table for two-way DC <-> DR sync (design in clickhouse-model.drawio, page 2).
-- Column list is a generic example; the engine / ordering / sync columns are what matter.
--
-- Run on BOTH clusters (once per cluster, on any node), AFTER every server has the
-- {site} macro (config.d/macros.xml: <site>DC</site> or <site>DR</site>); a missing macro
-- fails with "No macro site":
--   clickhouse-client --multiquery < ddl_events.sql
--
-- What the sync job needs from every synced table:
--   * *ReplacingMergeTree engine, ORDER BY contains the unique key (id) -> duplicate copies merge away
--   * _origin DEFAULT getMacro('site') -> a row carries the name of the site where it was written
--     and keeps it when copied, so each direction only copies the source site's rows (no loop)
--   * _ingested MATERIALIZED now()    -> watermark; not part of SELECT * / INSERT
--   * minmax index on _ingested       -> each sync pass only reads new parts

CREATE DATABASE IF NOT EXISTS db1 ON CLUSTER cluster_1S_3R;

CREATE TABLE IF NOT EXISTS db1.events_local ON CLUSTER cluster_1S_3R
(
    id          String,
    event_time  DateTime64(3),
    event_type  LowCardinality(String),
    source_code String,
    source_name String,
    site_code   String,
    latitude    Nullable(Float64),
    longitude   Nullable(Float64),
    attributes  Map(String, String),
    images      Array(String),

    -- sync columns
    _origin LowCardinality(String) DEFAULT getMacro('site'),
    _ingested DateTime MATERIALIZED now(),
    INDEX idx_ingested _ingested TYPE minmax GRANULARITY 1
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/events', '{replica}')
PARTITION BY toYYYYMMDD(event_time)       -- daily: TTL drops whole parts, cheap
ORDER BY (event_time, id)
TTL toDateTime(event_time) + INTERVAL 60 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS db1.events ON CLUSTER cluster_1S_3R
AS db1.events_local
ENGINE = Distributed(cluster_1S_3R, db1, events_local, sipHash64(id));
