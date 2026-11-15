# WebShuttle 节点协议的离线研究

该目录是根据用户提供的 Android 4.0.1 样本静态分析得到的协议实验，不是可用的 iOS 代理。未包含账号、节点密钥或用户数据。

观察到的路径包含节点探测、SOCKS5 连接请求，以及对隧道数据逐字节异或。`proxy_protocol.py` 仅对调用方提供的 socket 操作；不访问或发现任何真实节点。`tests/test_proxy_protocol.py` 使用本地 socket pair 模拟探测响应、分片握手、错误响应、SOCKS CONNECT 和一段数据转发。

运行：

```sh
python3 -m unittest discover -s tests -v
```

这是对静态逆向结果的自洽测试，不是对原版服务端的兼容性证明。尚未实现 iOS 原节点连接、自动节点切换、账号会员、DNS/UDP 或 VPN 模式。原实现中观察到的单字节异或不等同于现代加密，不能用于承诺隧道保密性。
