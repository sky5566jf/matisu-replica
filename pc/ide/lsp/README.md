# pc/ide/lsp — Lua 语言服务

IDE 编辑器的补全/悬浮/诊断由 [lua-language-server](https://github.com/LuaLS/lua-language-server)（lls）提供，
经 `server.js` 的 `/ws/lsp` WebSocket 桥接给浏览器里的 CodeMirror 6。

## 目录

- `meta/matisu.lua` — MatisuAuto 契约 API 的 EmmyLua 注解（由 `../editor-build/gen_api_meta.py`
  从 `common/lua-api/core.lua` 自动生成，勿手改）。
- `lls/` — lua-language-server 二进制（**不入仓**）。部署：下载对应平台 release 解压到此，
  使可执行文件位于 `lls/bin/lua-language-server[.exe]`（Windows 开发机可直接解压 `lls.zip`）。

## 关键机制（实测 lls 3.19.1）

- API 注解生效靠 **workspace root（`scripts/`）下的 `.luarc.json`**，由 `server.js` 启动时自动生成；
  `initializationOptions.settings` 与 lls cwd 下的配置均**不生效**。
- 诊断推送的 URI 盘符会被 lls 规范化（小写、`:` 编码为 `%3A`），比较前须做归一化
  （见 `editor-build/editor-src.js` 的 `normUri`）。

## 测试

- `node editor-build/lsp_bridge_test.js <port>` — WS 桥端到端（initialize/补全/悬浮/诊断）。
- `node editor-build/cdp_editor_test.js <port>` — headless Chrome 真实 UI（挂载/补全弹层）。
