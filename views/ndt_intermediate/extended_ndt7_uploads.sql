--
-- NDT7 upload data in standard columns plus additional annotations.
-- This contributes one portion of the data used by MLab standard Unified Views.
--
-- Anything here that is not visible in the unified views is subject to
-- breaking changes.  Use with caution!
--
-- See the documentation on creating custom unified views.
--

WITH

ndt7uploads AS (
  SELECT *,

  raw.Upload.ServerMeasurements[SAFE_ORDINAL(ARRAY_LENGTH(raw.Upload.ServerMeasurements))] AS FinalSnapshot,
-- (raw.Upload.Error != "") AS IsError,  -- TODO ndt-server/issues/317
  False AS IsError,
  TIMESTAMP_DIFF(raw.Upload.EndTime, raw.Upload.StartTime, MILLISECOND)*1.0 AS test_duration

  FROM`{{.ProjectID}}.ndt.ndt7`
  -- Limit to rows with valid C2S
  WHERE
  raw.Upload IS NOT NULL
  AND raw.Upload.UUID IS NOT NULL
  AND raw.Upload.UUID NOT IN ( '', 'ERROR_DISCOVERING_UUID' )
),

PreComputeNDT7 AS (
  SELECT
    -- All std columns top levels
    id, date, parser, server, client, a, raw,

    -- Computed above, due to sequential dependencies
    IsError, FinalSnapshot, test_duration,

    FinalSnapshot IS NOT NULL AS IsComplete, -- Not Missing any key fields

    -- Protocol
    CONCAT("ndt7",
      IF(raw.ClientIP LIKE "%:%", "-IPv6", "-IPv4"),
      CASE raw.ServerPort
        WHEN 443 THEN "-WSS"
        WHEN 80 THEN "-WS"
        ELSE "-unknown" END ) AS Protocol,

    -- TODO(https://github.com/m-lab/etl/issues/893) generalize IsOAM
    ( raw.ClientIP IN
        ( "35.193.254.117", -- script-exporter VMs in GCE, sandbox.
          "35.225.75.192", -- script-exporter VM in GCE, staging.
          "35.192.37.249", -- script-exporter VM in GCE, oti.
          "23.228.128.99", "2605:a601:f1ff:fffe::99", -- ks addresses.
          "45.56.98.222", "2600:3c03::f03c:91ff:fe33:819", -- eb addresses.
          "35.202.153.90", "35.188.150.110" -- Static IPs from GKE VMs for e2e tests.
        ) ) AS IsOAM,

    -- TODO(https://github.com/m-lab/k8s-support/issues/668) deprecate? _IsRFC1918
    ( (NET.IP_TRUNC(NET.SAFE_IP_FROM_STRING(raw.ClientIP),
                8) = NET.IP_FROM_STRING("10.0.0.0"))
      OR (NET.IP_TRUNC(NET.SAFE_IP_FROM_STRING(raw.ClientIP),
                12) = NET.IP_FROM_STRING("172.16.0.0"))
      OR (NET.IP_TRUNC(NET.SAFE_IP_FROM_STRING(raw.ClientIP),
                16) = NET.IP_FROM_STRING("192.168.0.0"))
    ) AS _IsRFC1918,

    REGEXP_CONTAINS(parser.ArchiveURL,
      'mlab[1-3]-[a-z][a-z][a-z][0-9][0-9]') AS IsProduction,

  FROM
    ndt7uploads
),

-- Standard cols must exactly match the Unified Upload Schema
UnifiedUploadSchema AS (
  SELECT
    id,
    date,
    STRUCT(
      a.UUID,
      a.TestTime,
      'Upload' AS Direction,
      'Unknown' AS CongestionControl, -- https://github.com/m-lab/etl-schema/issues/95
      a.MeanThroughputMbps,
      a.MinRTT,  -- mS
      Null AS LossRate  -- Receiver can not disambiguate reordering and loss
    ) AS a,

    STRUCT (
      'extended_ndt7_uploads' AS View,
      Protocol,
      raw.Upload.ClientMetadata AS ClientMetadata,
      raw.Upload.ServerMetadata AS ServerMetadata,
      -- TODO(https://github.com/m-lab/etl-schema/issues/140) Add annotations parseinfo
      [ parser ] AS Tables
    ) AS metadata,

    -- Struct filter has predicates for various cleaning assumptions
    STRUCT (
      IsComplete, -- Not Missing any key fields
      IsProduction,     -- Not mlab4, abc0t, or other pre production servers
      IsError,                  -- Server reported a problem
      IsOAM,               -- internal testing and monitoring
      _IsRFC1918,            -- Not a real client (deprecate?)
      False AS IsPlatformAnomaly, -- FUTURE, No switch discards, etc
      (FinalSnapshot.TCPInfo.BytesReceived < 8192) AS IsSmall, -- not enough data
      (test_duration < 9000.0) AS IsShort,   -- Did not run for enough time
      (test_duration > 60000.0) AS IsLong,    -- Ran for too long
      False AS _IsCongested,
      False AS _IsBloated
    ) AS filter,

    STRUCT (
      -- TODO(https://github.com/m-lab/etl-schema/issues/141) Relocate IP and port
      raw.ClientIP AS IP,
      raw.ClientPort AS Port,
      -- TODO(https://github.com/m-lab/etl/issues/1069): eliminate region mask once parser does this.
      STRUCT(
        client.Geo.ContinentCode,
        client.Geo.CountryCode,
        client.Geo.CountryCode3,
        client.Geo.CountryName,
        CAST(NULL as STRING) as Region, -- mask out region.
        client.Geo.Subdivision1ISOCode,
        client.Geo.Subdivision1Name,
        client.Geo.Subdivision2ISOCode,
        client.Geo.Subdivision2Name,
        client.Geo.MetroCode,
        client.Geo.City,
        client.Geo.AreaCode,
        client.Geo.PostalCode,
        client.Geo.Latitude,
        client.Geo.Longitude,
        client.Geo.AccuracyRadiusKm,
        client.Geo.Missing
      ) AS Geo,
      client.Network
    ) AS client,

    STRUCT (
      -- TODO(https://github.com/m-lab/etl-schema/issues/141) Relocate IP and port
      raw.ServerIP AS IP,
      raw.ServerPort AS Port,
      server.Site, -- e.g. lga02
      server.Machine, -- e.g. mlab1
      -- TODO(https://github.com/m-lab/etl/issues/1069): eliminate region mask once parser does this.
      STRUCT(
        server.Geo.ContinentCode,
        server.Geo.CountryCode,
        server.Geo.CountryCode3,
        server.Geo.CountryName,
        CAST(NULL as STRING) as Region, -- mask out region.
        server.Geo.Subdivision1ISOCode,
        server.Geo.Subdivision1Name,
        server.Geo.Subdivision2ISOCode,
        server.Geo.Subdivision2Name,
        server.Geo.MetroCode,
        server.Geo.City,
        server.Geo.AreaCode,
        server.Geo.PostalCode,
        server.Geo.Latitude,
        server.Geo.Longitude,
        server.Geo.AccuracyRadiusKm,
        server.Geo.Missing
      ) AS Geo,
      server.Network
    ) AS server,

    PreComputeNDT7 AS _internal202207  -- Not stable and subject to breaking changes

  FROM PreComputeNDT7
)

SELECT * FROM UnifiedUploadSchema
