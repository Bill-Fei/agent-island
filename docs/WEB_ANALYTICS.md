# 网站统计

本网站使用自己 Cloudflare 账户内的 Pages Worker + 独立 D1 数据库 `agent-island-analytics`。不依赖 Web Analytics beacon token，不修改作品集数据库。

## 已定义的指标

- `page_view`：浏览器打开页面时上报一次。不是独立访客数，刷新会再次计数。
- `click`：导航、短片播放、演示岛、来源链接和各下载入口的点击。
- `download_request`：安装包成功返回 200/206 的初始 GET 请求；排除 HEAD 和非零起点的 Range 续传。不是下载完成或安装完成，重复下载仍计数。
- 维度：UTC 日期、固定事件/目标、Cloudflare 提供的国家/地区、设备类别、来源类别（直接/搜索/社交/其他）。仅存汇总计数，无单访客明细。

## 隐私与限制

无 Cookie、访客 ID、原始 IP、精确位置、完整来源 URL、查询参数、原始 User-Agent、提示词或应用数据。尊重 DNT / GPC，过滤明显机器人。保留最近 90 个 UTC 自然日；每次写入时清理过期汇总。

Cloudflare 作为托管服务本身会处理连接 IP，但本统计库不保存 IP，也不声称可以从普通 Pages 页面查询逐次访问 IP。国家/地区取决于访问者网络出口（VPN 会改变结果）。公开事件入口不是防刷系统，可能受伪造流量、浏览器拦截和配额影响；不应用于计费或审计。若请求被拦截或超过配额，页面/下载不被阻塞，统计可能少记。

## 查看数据

在 Cloudflare → 存储和数据库 → D1 → `agent-island-analytics` → Console，运行：

```sql
SELECT day,event,target,SUM(count) AS total FROM daily_metrics
WHERE traffic='visitor' GROUP BY day,event,target ORDER BY day DESC,total DESC;
SELECT country,SUM(count) AS views FROM daily_metrics
WHERE traffic='visitor' AND event='page_view' GROUP BY country ORDER BY views DESC;
```

数据库只通过 Cloudflare 已登录控制台查看，网站上不开放公开统计明细接口。

## 发布与验证

稳定主站地址：https://agent-island.pages.dev/ 。部署哈希子域（如 `5a7d022e.agent-island.pages.dev`）是历史快照，不随新部署更新。

网页专用发布（保持现有 DMG，不构建/签名应用）：

```bash
node script/test_site_analytics.mjs
wrangler d1 execute agent-island-analytics --remote --file site/analytics-schema.sql
node script/publish_site_analytics.mjs --deploy
```

首次建库 ID 已放在 `site/wrangler.jsonc` 中，这不是凭据。未来完整发布脚本也带上统计文件，并从该配置绑定数据库。

测试网页用 `?analytics_test=1`，安装包测试请求也添加此参数；结果归入 `traffic='test'`，所有正式报表应筛选 `traffic='visitor'`。不要把测试行计入真实流量。

## 2026-10-11 验证记录

- 网站专用代码通过本地测试；未修改/重构建 macOS 应用。
- 已真实通过浏览器访问主站并点击隐私导航，远程数据库收到 `page_view` 与 `click/privacy` 测试汇总，含国家/地区。
- 安装包真实请求后数据库收到 `download_request` 测试汇总；线上文件 SHA256 与原安装包一致：`3b9ac0446a655ed62a4eb93e529c1a79653ca901ef22e2764647464df3666711`。
- 线上接口拒绝跨来源和非法事件目标；DNT/GPC 请求不增加点击计数；不开放公开统计读取接口。
- 已检查真实下载页画面与隐私说明。尚无下载完成/安装完成指标，也不提供原始 IP 明细。
- 免费额度、长期流量、防刷与全量可用性未做压力测试，不能当作审计/计费来源。
