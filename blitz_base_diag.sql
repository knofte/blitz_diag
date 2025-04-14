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
          THEN '⚠️ Low buffer pool efficiency.'
          ELSE '✅ Buffer pool efficiency okay.' END
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
