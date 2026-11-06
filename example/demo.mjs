import http from 'node:http';
import {createAccountApi} from '../account_api.mjs';
// 默认只启动本机健康检查；没有用户、数据库、发信、支付和模型连接。
const api = createAccountApi({authUrl:'https://auth.example.invalid',store:{}});
const server = http.createServer(api);
server.listen(Number(process.env.PORT ?? 8080), '127.0.0.1', () => console.log(`本机示例：http://127.0.0.1:${server.address().port}/health`));
process.on('SIGINT', () => server.close());
process.on('SIGTERM', () => server.close());
