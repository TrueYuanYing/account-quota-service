# 开发者自部署

这是新实例教程，不是原服务器运维入口。只使用自己的域名、数据库、邮件账号与ZPAY商户。公开仓库没有原服务凭据、SSH方式、管理码、生产配置或历史数据库。

## 先跑不联网示例

`npm ci && npm test` 运行模拟协议/HTTP测试；`npm start` 只在127.0.0.1:8080提供本机健康检查，支付为false。不要把这个空store示例当成完整账号服务。完整入口是 `npm run start:service`。

## 新实例顺序

1. 准备Docker Compose v2、HTTPS反向代理与持久卷。复制 `.env.example` 为本机 `.env`，生成独立强密码与随机密钥；不要复用示例占位值。将官方PostgreSQL/GoTrue镜像固定为核验过的digest。仓库 `deploy/compose.yaml` 是关闭SMTP/支付/模型的开发模板，不能直接称生产已验收。
2. 启动数据库；`deploy/init-db.sh` 在首次空卷创建auth及最小业务角色，数据库不开放公网。启动GoTrue等待其auth schema迁移完成。确认 `auth.users` 存在，再用 `deploy/migrate.sh` 按001–013顺序初始化iko schema；脚本拒绝已有iko schema，避免把历史补发迁移盲跑到已有库。
3. 核对业务角色权限与最新catalog86/87、四类额度和计次函数，再启动API。Auth/API只绑定回环，由自己的HTTPS网关转发。反向代理限制请求体、超时、可信forwarded headers和邮件防滥发；数据库与管理端口保持私网。
4. 配置事务邮件：验证自己的发信域SPF/DKIM/DMARC、SMTP端口/凭据与发件人。开发模板不含SMTP；仅在真实可收信与防刷验证后配置这些变量并开放注册。前端60秒冷却不能代替服务端频率和失败次数限制。
5. 配置ZPAY：服务端设置PID/CID/KEY、PAYMENT_LINK_KEY与PUBLIC_ACCOUNT_URL；检查商户专属H5、notify/查单协议与HTTPS。先保持ZPAY_ENABLED=0跑mock，只有自己参与真实支付验证后才开启1。return页仅展示，不接收“已支付”授权。
6. 配置模型：MODEL_DATABASE_URL启用独立计量角色，ACCOUNT_PROXY_KEY为随机64位hex；MODEL_RELAY_URL指向自己可控的可信代理，或配置加密供应商注册表。真实供应商Key只在服务端安全存储。明确计次、成本与并发，先小额质量验证，不自动收费重试。

模板快速开始（先填写自己的配置）：

```sh
cp .env.example .env
docker compose -f deploy/compose.yaml --env-file .env up -d db auth
docker compose -f deploy/compose.yaml --env-file .env run --rm migrate
docker compose -f deploy/compose.yaml --env-file .env up -d api
curl http://127.0.0.1:8080/health
```

模板已把`.env`中的SMTP、ZPAY、模型与支付连接变量映射进相应容器；默认`MODEL_DATABASE_URL`、`PAYMENT_DATABASE_URL`留空，`ZPAY_ENABLED=0`、`AUTH_DISABLE_SIGNUP=true`。启用支付时将PAYMENT_DATABASE_URL设为自己的`postgres://iko_payments:<密码>@db:5432/iko`，填写ZPAY与链接密钥后，自己参与验证再改开关；模型连接同理使用iko_model角色。URI中的密码必须URL编码，或生成hex格式数据库密码避免保留字符。

邮件需要SMTP_HOST/PORT/USER/PASSWORD/ADMIN_EMAIL/SENDER_NAME，MAIL_TEMPLATE_URL指向自己HTTPS静态托管的`deploy/email-otp.html`（保留GoTrue模板变量`{{ .Token }}`）。该模板不含品牌图片或外部脚本。确认真实收码与防刷后再开放注册。保存`.env`后需要重新创建相应容器，模板不会自动热加载服务器环境。

公开Auth地址与anon/publishable key才可进入客户端；SMTP、JWT签名secret/service_role、DB和支付Key绝不能进入APK。需要客户端JWT的部署应使用与GoTrue相同签名策略的anon token，由实例所有者在服务器生成，不能把service_role当public key。

## 变量和默认关闭边界

`.env.example`列出模板需要的变量。完整源码还支持MODEL_JOURNAL_DIRECTORY、PROVIDER_DIRECTORY、LEGACY_BALANCE_URL、ADMIN_STATUS_URL。遗留管理员授权端点默认example.invalid，不连接原后台；普通新实例若不实现管理员鉴权适配，该功能不可用。付款图标也使用占位域名，可替换为自有静态资源或移除。容器内journal/providers必须持久化并限制权限。

## 迁移、备份与恢复

首次安装必须有GoTrue的auth.users和iko_api/iko_model/iko_payments角色；否则后续GRANT/外键失败。001/002存在历史月度商品，011更新到累计额度，不能只执行前两份。013含历史差额补发函数，在空库无效果；已有实例升级必须先逐份审查并备份，不用首次初始化脚本覆盖。

定期 `pg_dump` 加密保存到与主机分离的位置，记录数据库和业务源码版本；供应商加密配置备份必须配套独立安全保存的密钥。恢复先在全新隔离库演练，核账号、订单、四类余额/已用/预占、审计、迁移版本，再测试查单与未完成请求恢复。未做恢复演练不能写“备份可恢复”。

## 健康、容量与排错

监控/health、Auth健康、DB连接池、磁盘、5xx、邮件发送失败、模型并发和账本待核。capacity在磁盘查询失败或空间不足时保护性拒绝新写请求；主机指标文件缺失或过期时，继续使用磁盘、进程RSS与并发限制，94%宿主机内存阈值不生效。本模板未挂载主机指标，若需要该阈值，应另接可信的指标采集和只读挂载，不能把未采集的内存状态写成已验证。

数据库超时先查私网/DNS/角色权限；验证码失败查SMTP与域验证；回调成功但未到账查整数分金额、商户/渠道、二次查单与幂等事务；模型错误先区分前置拒绝和已派发，不能手工清预占掩盖未知终态。管理员撤销权益不是支付退款。

本次没有运行Docker/真实PostgreSQL部署、真实发信或付款；模板已进行静态检查的具体范围见VALIDATION。香港/新加坡可按自己的网络与合规需求选择，服务器、邮件、网关与模型费用分开计，本文没有实测承载人数。
