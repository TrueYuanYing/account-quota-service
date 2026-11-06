# 第三方来源与发布边界

根 LICENSE 只覆盖本人有权许可的代码与本次原创适配/文档；第三方实现、许可证文字、商标与资源不因此改为MIT。没有把“可以查看的网页/目录”当成可以统一再许可的素材库。依赖安装时以锁文件和包内许可为准。

Node业务代码为本项目实现；pg为MIT，通过npm锁文件安装。GoTrue为官方Supabase Auth独立服务（其上游许可独立），PostgreSQL使用PostgreSQL License；Docker镜像不在本仓库分发。客户端参考依赖gotrue、flutter_secure_storage、Dio、qr_flutter等，按自己的依赖许可使用。

ZPAY是外部支付协议/服务，不是本MIT许可承诺的免费网关；不得使用别人的商户信息。SMTP/事务邮件/模型供应商各有服务条款和费用。没有复制专用生产部署脚本、管理APK、商户Key、生产域名、用户资料或原Git历史。
