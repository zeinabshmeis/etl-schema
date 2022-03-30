--
-- NDT7 download data in standard columns plus additional annotations.
-- This contributes one portion of the data used by MLab standard Unified Views.
--
-- Anything here that is not visible in the unified views is subject to
-- breaking changes.  Use with caution!
--
-- See the documentation on creating custom unified views.
--

WITH ndt7downloads AS (
  SELECT *,
  raw.Download.ServerMeasurements[SAFE_ORDINAL(ARRAY_LENGTH(raw.Download.ServerMeasurements))] AS lastSample,
# (raw.Download.Error != "") AS IsErrored,  -- TODO ndt-server/issues/317
  False AS IsErrored,
  TIMESTAMP_DIFF(raw.Download.EndTime, raw.Download.StartTime, MICROSECOND) AS connection_duration
 FROM   `{{.ProjectID}}.ndt.ndt7` -- TODO move to intermediate_ndt
  -- Limit to valid S2C results
  WHERE raw.Download IS NOT NULL
  AND raw.Download.UUID IS NOT NULL
  AND raw.Download.UUID NOT IN ( '', 'ERROR_DISCOVERING_UUID' )
),

PreCleanNDT7 AS (
  SELECT
    id, date, a, IsErrored, lastsample,
    connection_duration, raw,
    client, server,
    -- Any loss implys a netowork bottleneck
    (lastSample.TCPInfo.TotalRetrans > 0) AS IsCongested,
    -- Final RTT sample twice the minimum and above 1 second means bloated
    ((lastSample.TCPInfo.RTT > 2*lastSample.TCPInfo.MinRTT) AND
       (lastSample.TCPInfo.RTT > 1000)) AS IsBloated,
    ( -- IsOAM
      raw.ClientIP IN
         -- TODO(m-lab/etl/issues/893): move to parser configuration.
        ( "35.193.254.117", -- script-exporter VMs in GCE, sandbox.
          "35.225.75.192", -- script-exporter VM in GCE, staging.
          "35.192.37.249", -- script-exporter VM in GCE, oti.
          "23.228.128.99", "2605:a601:f1ff:fffe::99", -- ks addresses.
          "45.56.98.222", "2600:3c03::f03c:91ff:fe33:819", -- eb addresses.
          "35.202.153.90", "35.188.150.110" -- Static IPs from GKE VMs for e2e tests.
        )
      OR (NET.IP_TRUNC(NET.SAFE_IP_FROM_STRING(raw.ServerIP),
                8) = NET.IP_FROM_STRING("10.0.0.0"))
      OR (NET.IP_TRUNC(NET.SAFE_IP_FROM_STRING(raw.ServerIP),
                12) = NET.IP_FROM_STRING("172.16.0.0"))
      OR (NET.IP_TRUNC(NET.SAFE_IP_FROM_STRING(raw.ServerIP),
                16) = NET.IP_FROM_STRING("192.168.0.0"))
    ) AS IsOAM,  -- Data is not from valid clients
    parser AS NDT7parser,
  FROM
    ndt7downloads
),

NDT7DownloadModels AS (
  SELECT
    id,
    date,
    STRUCT (
      a.UUID,
      a.TestTime,
      a.CongestionControl,
      a.MeanThroughputMbps,
      a.MinRTT,  -- mS
      a.LossRate
    ) AS a,
    STRUCT (
     -- "Instruments" is not quite the right concept
     "ndt7" AS _Instruments -- THIS WILL CHANGE
    ) AS node,
    -- Struct filter has predicates for various cleaning assumptions
    STRUCT (
      (
        NOT IsOAM AND NOT IsErrored
        AND lastSample.TCPInfo.BytesAcked IS NOT NULL
        AND lastSample.TCPInfo.BytesAcked >= 8192
        AND connection_duration BETWEEN 9000000 AND 60000000
        -- Tests without network bottlenecks are presumed to have bottlenecks elsewhere
        AND ( IsCongested OR IsBloated ) -- Loss or excess queueing indicates congestion
      ) AS IsValidBest,
      (
        NOT IsOAM AND NOT IsErrored
        AND lastSample.TCPInfo.BytesAcked IS NOT NULL
        AND lastSample.TCPInfo.BytesAcked >= 8192
        AND connection_duration BETWEEN 9000000 AND 60000000
        AND ( IsCongested ) -- Only consides loss as a congestion signal
      ) AS IsValid2019
    ) AS filter,
    -- NOTE: standard columns for views exclude the parseInfo struct because
    -- multiple tables are used to create a derived view. Users that want the
    -- underlying parseInfo values should refer to the corresponding tables
    -- using the shared UUID.
    STRUCT (
      raw.ClientIP AS IP,
      raw.ClientPort AS Port,
      -- TODO(https://github.com/m-lab/etl/issues/1069): eliminate region mask once parser does this.
      STRUCT(
        client.Geo.ContinentCode,
        client.Geo.CountryCode,
        client.Geo.CountryCode3,
        client.Geo.CountryName,
        NULL as Region, -- mask out region.
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
        NULL as Region, -- mask out region.
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
    PreCleanNDT7 AS _internal202010  -- Not stable and subject to breaking changes

  FROM PreCleanNDT7
)

SELECT * FROM NDT7DownloadModels
