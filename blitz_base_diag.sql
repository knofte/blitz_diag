-- blitz_base_diag.sql
-- Stored procedure: blitz_diag()
-- Version that stores diagnostics in a single output table for clarity

CREATE DATABASE IF NOT EXISTS blitz_diag42;
USE blitz_diag42;

DROP PROCEDURE IF EXISTS blitz_diag;
DROP TABLE IF EXISTS blitz_output;

CREATE TABLE blitz_output (
  section_order INT,
  section_name VARCHAR(255),
  info_text TEXT,
  data TEXT
);

DELIMITER //
CREATE PROCEDURE blitz_diag()
BEGIN
  DECLARE done INT DEFAULT FALSE;
  DECLARE cur_section INT DEFAULT 0;

  -- Helper to insert rows
  -- Note: This is simplified. For production, use prepared statements for complex data types

  -- Replication Status
  SET cur_section := cur_section + 1;
  IF EXISTS (SELECT 1 FROM information_schema.processlist WHERE user = 'replication' OR command = 'Binlog Dump') THEN
    INSERT INTO blitz_output
    SELECT cur_section, 'Replication Status', 'Replication appears to be enabled — review lag and connection status (#00):',
           CONCAT_WS(', ',
             'Slave_IO_Running: ', (SELECT Slave_IO_Running FROM mysql.slave_status LIMIT 1),
             'Slave_SQL_Running: ', (SELECT Slave_SQL_Running FROM mysql.slave_status LIMIT 1),
             'Seconds_Behind_Master: ', (SELECT Seconds_Behind_Master FROM mysql.slave_status LIMIT 1)
           );
  ELSE
    INSERT INTO blitz_output VALUES (cur_section, 'Replication Status', 'Replication not enabled or not configured.', '⚠️ No replication detected.');
  END IF;

  -- Security Check: root@% with no password
  SET cur_section := cur_section + 1;
  INSERT INTO blitz_output
  SELECT cur_section, 'Root Access Check', 'Checks if root user has remote access with no password (#09):',
         IF(COUNT(*) > 0, '⚠️ Found root@% with empty password!', '✅ No insecure root@% access found.')
  FROM mysql.user
  WHERE User = 'root' AND Host = '%' AND (authentication_string = '' OR authentication_string IS NULL);

  -- Server Info
  SET cur_section := cur_section + 1;
  INSERT INTO blitz_output VALUES
  (cur_section, 'Server Version', 'Detected server version and flavor', CONCAT('Version: ', VERSION(), ', Flavor: ', @@version_comment));

  -- Query Cache
  SET cur_section := cur_section + 1;
  INSERT INTO blitz_output VALUES
  (cur_section, 'Query Cache', 'Query Cache usage stats — usually best left OFF unless you know it helps (#01)',
   CONCAT('Type: ', @@query_cache_type,
          ', Size: ', @@query_cache_size,
          ', Hits: ', (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Qcache_hits'),
          ', Inserts: ', (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Qcache_inserts'),
          ', Lowmem Prunes: ', (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Qcache_lowmem_prunes')));

  -- InnoDB Buffer Pool
  SET cur_section := cur_section + 1;
  SET @pool_reads := (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads');
  SET @pool_read_requests := (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests');
  SET @pool_efficiency := ROUND(100 * (1 - (@pool_reads / @pool_read_requests)), 2);
  INSERT INTO blitz_output VALUES
  (cur_section, 'InnoDB Buffer Pool', 'Buffer pool efficiency is key to read performance — see #02 for tuning strategies:',
   CONCAT('Size: ', ROUND(@@innodb_buffer_pool_size / 1024 / 1024), 'MB',
          ', Reads from disk: ', @pool_reads,
          ', Logical reads: ', @pool_read_requests,
          ', Efficiency: ', @pool_efficiency, '%'));

  -- Temp Table Usage
  SET cur_section := cur_section + 1;
  SET @tmp_disk := (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Created_tmp_disk_tables');
  SET @tmp_all := (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Created_tmp_tables');
  SET @tmp_pct := ROUND((@tmp_disk / @tmp_all) * 100, 1);
  SET @tmp_size := ROUND(@@tmp_table_size / 1024 / 1024);
  SET @heap_size := ROUND(@@max_heap_table_size / 1024 / 1024);
  INSERT INTO blitz_output VALUES
  (cur_section, 'Temp Tables', 'Disk-based temp tables are expensive — check ratio of disk to memory-created temp tables (#03):',
   CONCAT('Disk temp tables: ', @tmp_disk, ' / ', @tmp_all, ' (', @tmp_pct, '%)',
          '
tmp_table_size: ', @tmp_size, 'MB',
          ', max_heap_table_size: ', @heap_size, 'MB',
          '
Efficiency: ',
          CASE
            WHEN @tmp_pct > 25 THEN '⚠️ High disk usage (above 25%) — consider increasing tmp_table_size or optimizing queries.'
            ELSE '✅ OK (disk usage below 25%)'
          END));

  -- max_allowed_packet Check
  SET cur_section := cur_section + 1;
  SET @max_packet_mb := ROUND(@@max_allowed_packet / 1024 / 1024);
  INSERT INTO blitz_output VALUES
  (cur_section, 'max_allowed_packet', 'Packet size limit for bulk operations — low values cause "server has gone away" errors:',
   CONCAT('Current: ', @max_packet_mb, 'MB',
          CASE
            WHEN @@max_allowed_packet < 67108864 THEN ' ⚠️ Low for bulk inserts/exports. Suggest setting to 64M or 128M in my.cnf.'
            ELSE ' ✅ Adequate for most workloads.'
          END));

  -- table_open_cache Usage
  SET cur_section := cur_section + 1;
  SET @opened_tables := (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Opened_tables');
  SET @table_open_cache_hits := IFNULL((SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Table_open_cache_hits'), 0);
  SET @table_open_cache_misses := IFNULL((SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Table_open_cache_misses'), 0);
  SET @cache_total_requests := @table_open_cache_hits + @table_open_cache_misses;
  SET @cache_miss_pct := CASE WHEN @cache_total_requests > 0 THEN ROUND((@table_open_cache_misses / @cache_total_requests) * 100, 3) ELSE 0 END;
  INSERT INTO blitz_output VALUES
  (cur_section, 'table_open_cache Usage', 'Table cache performance — misses force expensive table reopens:',
   CONCAT('Cache size: ', @@table_open_cache,
          ', Opened_tables: ', @opened_tables,
          ', Hits: ', @table_open_cache_hits,
          ', Misses: ', @table_open_cache_misses,
          ', Miss rate: ', @cache_miss_pct, '%',
          CASE
            WHEN @cache_miss_pct > 1 THEN ' ⚠️ High miss rate (>1%) — consider increasing table_open_cache.'
            ELSE ' ✅ Good cache performance.'
          END));

  -- thread_cache_size Efficiency
  SET cur_section := cur_section + 1;
  SET @threads_created := (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Threads_created');
  SET @connections := (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Connections');
  SET @thread_creation_pct := CASE WHEN @connections > 0 THEN ROUND((@threads_created / @connections) * 100, 2) ELSE 0 END;
  INSERT INTO blitz_output VALUES
  (cur_section, 'thread_cache_size Efficiency', 'Thread cache reduces overhead of thread creation for new connections:',
   CONCAT('Cache size: ', @@thread_cache_size,
          ', Threads_created: ', @threads_created,
          ', Total connections: ', @connections,
          ', Creation rate: ', @thread_creation_pct, '%',
          CASE
            WHEN @thread_creation_pct > 2 THEN ' ⚠️ High thread creation rate (>2%) — consider increasing thread_cache_size.'
            ELSE ' ✅ Thread cache working well.'
          END));

  -- max_used_connections vs max_connections
  SET cur_section := cur_section + 1;
  SET @max_used_connections := (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Max_used_connections');
  SET @max_connections := @@max_connections;
  SET @connection_usage_pct := ROUND((@max_used_connections / @max_connections) * 100, 1);
  INSERT INTO blitz_output VALUES
  (cur_section, 'Connection Limit Usage', 'Peak connection usage vs configured maximum:',
   CONCAT('Max_used_connections: ', @max_used_connections,
          ' of ', @max_connections,
          ' (', @connection_usage_pct, '%)',
          CASE
            WHEN @connection_usage_pct > 80 THEN ' ⚠️ High usage (>80%) — risk of hitting connection limit. Consider increasing max_connections.'
            ELSE ' ✅ No risk of hitting connection limit.'
          END));

  -- aborted_connects Check
  SET cur_section := cur_section + 1;
  SET @aborted_connects := (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Aborted_connects');
  INSERT INTO blitz_output VALUES
  (cur_section, 'Aborted Connections', 'Dropped client connections can indicate network issues or authentication problems:',
   CONCAT('Aborted_connects: ', @aborted_connects,
          CASE
            WHEN @aborted_connects > 0 THEN ' ⚠️ Some connections were aborted — check for network issues or authentication failures.'
            ELSE ' ✅ No aborted connections detected.'
          END));

  -- key_buffer_size for MyISAM (only if MyISAM tables exist)
  SET cur_section := cur_section + 1;
  SET @myisam_index_size := IFNULL((
    SELECT SUM(index_length)
    FROM information_schema.tables
    WHERE engine = 'MyISAM'
      AND table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  ), 0);
  SET @key_buffer_mb := ROUND(@@key_buffer_size / 1024 / 1024);
  SET @myisam_index_mb := ROUND(@myisam_index_size / 1024 / 1024);
  INSERT INTO blitz_output VALUES
  (cur_section, 'key_buffer_size (MyISAM)', 'Key buffer size vs MyISAM index requirements:',
   CONCAT('Key buffer: ', @key_buffer_mb, 'MB',
          ', MyISAM index size: ', @myisam_index_mb, 'MB',
          CASE
            WHEN @myisam_index_size = 0 THEN ' ✅ No MyISAM tables found.'
            WHEN @key_buffer_mb < @myisam_index_mb THEN ' ⚠️ Key buffer smaller than MyISAM indexes — consider increasing key_buffer_size.'
            ELSE ' ✅ Key buffer adequate for MyISAM indexes.'
          END));

  -- Threads_created Trend Analysis
  SET cur_section := cur_section + 1;
  INSERT INTO blitz_output VALUES
  (cur_section, 'Thread Cache Effectiveness', 'Analysis of thread creation patterns for connection-heavy applications:',
   CONCAT('Thread cache size: ', @@thread_cache_size,
          ', Threads created: ', @threads_created,
          ', Total connections: ', @connections,
          CASE
            WHEN @connections > 1000 AND @thread_creation_pct < 1 THEN ' ✅ Excellent thread cache efficiency for high-connection environment.'
            WHEN @connections > 1000 AND @thread_creation_pct < 2 THEN ' ✅ Good thread cache efficiency.'
            WHEN @connections > 1000 AND @thread_creation_pct >= 2 THEN ' ⚠️ Thread cache may be too small for connection-heavy workload.'
            ELSE ' ✅ Thread cache working well for current connection volume.'
          END));

  -- Summary Warnings
  SET cur_section := cur_section + 1;
  INSERT INTO blitz_output VALUES
  (cur_section, 'Summary', 'Key performance flags based on heuristics:',
   CONCAT(
     CASE WHEN @@query_cache_type IN ('ON', 'DEMAND') AND @@query_cache_size > 0
          THEN '⚠️ Query Cache enabled. '
          ELSE '✅ Query Cache off. ' END,
     CASE WHEN ((SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Created_tmp_disk_tables') * 1.0 /
                (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Created_tmp_tables')) > 0.25
          THEN '⚠️ High temp table disk usage. '
          ELSE '✅ Temp table usage okay. ' END,
     CASE WHEN ((SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') * 1.0 /
                (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests')) > 0.05
          THEN '⚠️ Low buffer pool efficiency. '
          ELSE '✅ Buffer pool efficiency okay. ' END,
     CASE WHEN @@max_allowed_packet < 67108864
          THEN '⚠️ Low max_allowed_packet. '
          ELSE '✅ max_allowed_packet adequate. ' END,
     CASE WHEN (((SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Table_open_cache_misses') * 1.0) / 
                (GREATEST((SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Table_open_cache_hits') + 
                         (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Table_open_cache_misses'), 1))) > 0.01
          THEN '⚠️ High table cache miss rate. '
          ELSE '✅ Table cache working well. ' END,
     CASE WHEN (((SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Threads_created') * 1.0) /
                GREATEST((SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Connections'), 1)) > 0.02
          THEN '⚠️ High thread creation rate. '
          ELSE '✅ Thread cache efficient. ' END,
     CASE WHEN (((SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Max_used_connections') * 1.0) / @@max_connections) > 0.8
          THEN '⚠️ High connection usage. '
          ELSE '✅ Connection usage okay. ' END,
     CASE WHEN (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Aborted_connects') > 0
          THEN '⚠️ Aborted connections detected. '
          ELSE '✅ No aborted connections. ' END
   ));

  -- Tables Without Primary Key
  SET cur_section := cur_section + 1;
  INSERT INTO blitz_output
  SELECT cur_section, 'Missing Primary Keys', 'These tables are missing a PRIMARY KEY (#04):',
         IFNULL(GROUP_CONCAT(CONCAT(table_schema, '.', table_name) SEPARATOR '
'), '✅ None found — good job!')
  FROM (
    SELECT t.table_schema, t.table_name
    FROM information_schema.tables t
    LEFT JOIN information_schema.columns c
      ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND c.column_key = 'PRI'
    WHERE t.table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys', 'blitz_diag42')
      AND c.column_name IS NULL
  ) AS sub;

  -- MyISAM Tables
  SET cur_section := cur_section + 1;
  INSERT INTO blitz_output
  SELECT cur_section, 'MyISAM Tables', 'These tables use the legacy MyISAM engine — consider converting to InnoDB (#05):',
         IFNULL(GROUP_CONCAT(CONCAT(table_schema, '.', table_name) SEPARATOR ' | '), '✅ None found — good job!')
  FROM information_schema.tables
  WHERE engine = 'MyISAM'
    AND table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');

  -- Foreign Key Mismatches
  SET cur_section := cur_section + 1;
  INSERT INTO blitz_output
  SELECT cur_section, 'Foreign Key Mismatches', 'These foreign keys have mismatched column types (#06):',
         IFNULL(GROUP_CONCAT(CONCAT(fk_schema, '.', fk_table, '(', fk_column, ') -> ', ref_table, '.', ref_column, ' [', fk_column_type, ' ≠ ', ref_column_type, ']') SEPARATOR '
'), '✅ None found — good job!')
  FROM (
    SELECT kcu.table_schema AS fk_schema, kcu.table_name AS fk_table, kcu.column_name AS fk_column,
           c1.column_type AS fk_column_type,
           kcu.referenced_table_name AS ref_table, kcu.referenced_column_name AS ref_column,
           c2.column_type AS ref_column_type
    FROM information_schema.key_column_usage kcu
    JOIN information_schema.columns c1
      ON kcu.table_schema = c1.table_schema AND kcu.table_name = c1.table_name AND kcu.column_name = c1.column_name
    JOIN information_schema.columns c2
      ON kcu.referenced_table_schema = c2.table_schema AND kcu.referenced_table_name = c2.table_name AND kcu.referenced_column_name = c2.column_name
    WHERE kcu.referenced_table_name IS NOT NULL
      AND (c1.column_type != c2.column_type OR c1.data_type != c2.data_type)
  ) AS mismatches;

  -- Index to Data Ratio
  SET cur_section := cur_section + 1;
  INSERT INTO blitz_output
  SELECT cur_section, 'Index-to-Data Ratio', 'Top 20 tables by index-to-data ratio — may indicate over-indexing or low data volume (#07):',
         IFNULL(
           (SELECT GROUP_CONCAT(CONCAT(table_schema, '.', table_name, ' [', ROUND(index_length / data_length, 2), ']') SEPARATOR '
')
            FROM (
              SELECT table_schema, table_name, index_length, data_length
              FROM information_schema.tables
              WHERE table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys', 'blitz_diag42')
                AND data_length > 0
              ORDER BY index_length / data_length DESC
              LIMIT 20
            ) AS sub),
           '✅ None found — good job!');

  -- Long-Running Queries (requires performance_schema)
  SET cur_section := cur_section + 1;
  IF (SELECT @@performance_schema) THEN
    INSERT INTO blitz_output
    SELECT cur_section, 'Long-Running Queries', 'Top 10 slowest query digests from performance_schema (#08):',
           IFNULL(GROUP_CONCAT(CONCAT(SUBSTRING(digest_text, 1, 100), ' (', ROUND(SUM_TIMER_WAIT/1000000000000, 2), 's)') ORDER BY SUM_TIMER_WAIT DESC SEPARATOR '
'), '✅ None found — good job!')
    FROM performance_schema.events_statements_summary_by_digest
    ORDER BY SUM_TIMER_WAIT DESC
    LIMIT 10;
  ELSE
    INSERT INTO blitz_output VALUES (cur_section, 'Long-Running Queries', 'Performance schema not enabled. Enable with performance_schema=ON in my.cnf', '⚠️ Cannot analyze query performance without performance_schema.');
  END IF;

  -- Output all results
  SELECT * FROM blitz_output ORDER BY section_order;
END //
DELIMITER ;

-- Usage:
-- CALL blitz_diag();
-- Results will be shown in blitz_output table.
