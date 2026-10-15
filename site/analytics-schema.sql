-- Aggregate rows only. No IPs, cookies, user IDs, full URLs or raw User-Agent.
CREATE TABLE IF NOT EXISTS daily_metrics (
  day TEXT NOT NULL,
  event TEXT NOT NULL CHECK(event IN ('page_view','click','download_request')),
  target TEXT NOT NULL,
  country TEXT NOT NULL,
  device TEXT NOT NULL,
  source TEXT NOT NULL,
  traffic TEXT NOT NULL CHECK(traffic IN ('visitor','test')),
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(day,event,target,country,device,source,traffic)
) WITHOUT ROWID;

-- New engagement counters live separately so existing daily_metrics rows remain intact.
-- A bucket is a fixed category, never a per-visitor identifier.
CREATE TABLE IF NOT EXISTS engagement_metrics (
  day TEXT NOT NULL,
  metric TEXT NOT NULL CHECK(metric IN ('visible_time','scroll_depth','film_complete')),
  bucket TEXT NOT NULL,
  traffic TEXT NOT NULL CHECK(traffic IN ('visitor','test')),
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(day,metric,bucket,traffic)
) WITHOUT ROWID;
