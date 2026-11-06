# 账号、支付与额度账本

从实际发布服务提取账号HTTP边界、GoTrue会话验证、ZPAY订单、幂等入账、四类额度、模型派发日志、容量保护和供应商注册表。所有原生产域名已从公开副本移除，部署端点通过环境配置或 example.invalid 指定。默认只运行本机空服务，不发信、不付款、不连接数据库或模型。

```sh
# Node >=22，验证环境 Node 24.18.0
npm ci
npm test
npm start
# 另一个终端
curl http://127.0.0.1:8080/health
```

完整数据库服务是 `npm run start:service`，必须先配置自己的数据库/Auth；不能把健康检查示例当成账号注册已可用。普通用户看 [账号、个人API与充值](docs/USER-GUIDE.md)，开发者看 [部署](docs/DEPLOYMENT.md)、[账本与支付原理](docs/ARCHITECTURE.md)。

## 文件导航

| 文件 | 作用 |
| --- | --- |
| account_api / account_identity / account_management | 验证用户、本人资料、通知与管理员审计边界 |
| zpay_protocol / zpay_checkout | 签名、固定金额订单、H5、回调核对与查单 |
| account_store / migrations | PostgreSQL账户、订单与额度事务 |
| account_model / model_journal | 请求摘要与幂等、已派发计次、崩溃恢复 |
| capacity / provider_registry / provider_gateway | 并发保护、AES-GCM配置、单连接派发 |

旧的“30天月度/永久激活码”方案不是当前普通账号商品；管理版管理员激活制度也不是普通账号购买额度。公开副本不带管理APK或访问原后台的配置。[本次验证](VALIDATION.md) 与原产品历史上线证据分开；真实SMTP、ZPAY和生产数据库未在本次整理中操作。
