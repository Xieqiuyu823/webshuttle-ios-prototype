# iOS 浏览器原型

这是根据对 WebShuttle 4.0.1 的静态分析独立编写的 iOS 17+ 浏览器原型，不是官方 WebShuttle。项目未包含 WebShuttle 原节点、私有协议、账号或会员服务，不能保证与原应用功能完整一致。

目前实现的功能：网页浏览、多标签、书签与历史、WebKit 下载、少量内置广告域名过滤、自定义页面脚本，以及用户自行配置的 HTTP CONNECT 或 SOCKS5 代理。尚未实现完整广告过滤规则、油猴 GM 接口、视频嗅探、VPN 模式与会员系统。下载和代理的设备行为尚未验证；请勿依赖本原型保护身份或认为所有流量均经过代理。

## 编译

在装有 Xcode 与 XcodeGen 的 Mac 上：

```sh
xcodegen generate
xcodebuild -project BrowserPrototype.xcodeproj -scheme BrowserPrototype \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

GitHub Actions 的 **Build unsigned IPA** 工作流可手动编译，生成的未签名 IPA 保留 7 天，需要自行签名安装。该工作流不会自动发布。
