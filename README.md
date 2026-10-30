# 校园网自动认证工具

> 河南工学院（HAIT）校园网自动登录 · 纯 PowerShell · 零依赖 · 无需安装 Python / 浏览器插件

连上校园网后自动检测强制门户并完成认证，登录后自动等待并复检网络。账号、密码、运营商、等待时间全部可自定义。

## 🔍 三步自查：你的学校能不能用

#### ✅ 已实证兼容的学校
河南工学院、河南大学、河南科技学院、福州大学等

#### 🔍 三步自查：你的学校能不能用
连上校园网（先不认证），看弹出/跳转的页面：
1. 连上校园网（先不认证），看弹出/跳转的页面：地址栏是不是 http://x.x.x.x:6060/portalReceiveAction.do?wlanuserip=...&wlanacname=... 的形式
2. F12 看页面源码，里面有没有 /PortalJsonAction.do 和 /quickauth.do
3. 两个都满足 → 开箱即用，只需把 config.json 里的 isp_suffix 换成你校的后缀（后缀写在各校门户的 common.js 里，比如 HAIT 是 @gxydx、河大是 @henudx、河南科技学院是 @kjxyyd，规律通常是"@学校缩写+运营商"）

## 功能

- ✅ **自动检测**：监控网络状态变化（换 WiFi / 重连 / IP 变化），发现被强制门户拦截时自动认证
- ✅ **静默登录**：后台完成认证，无需手动打开网页、填表、点登录
- ✅ **运营商可选**：校园网本地 / 移动 / 联通 / 电信，一键切换
- ✅ **可自定义**：账号、密码、运营商、等待时间、重试次数等全部在配置文件中修改
- ✅ **失败自愈**：认证失败自动重试，登录后等待 N 秒（默认 5 秒）复检网络
- ✅ **运行日志**：全过程写入日志，失败时保留抓包现场便于排查

## 快速开始

1. 下载仓库的整合包 '校园网自动登录工具.zip'并讲其中所有文件解压到同一文件夹下
2. 用记事本打开 `config.json`，填写 `account`（学号）、 `password`和`isp`（运营商）
3. 连上校园网 WiFi
4. 双击 `立即登录.bat` 手动跑一次，或双击 `启动后台监控.vbs` 让它常驻后台自动认证

就这么简单。详细配置见下文。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `autologin.ps1` | 主程序（`-Mode once` 单次 / `-Mode monitor` 后台监控） |
| `config.example.json` | 配置模板：复制为 `config.json` 后填写账号密码 |
| `立即登录.bat` | 双击 = 手动认证一次（有窗口，可观察过程） |
| `启动后台监控.vbs` | 双击 = 后台常驻监控（无窗口，网络变化自动认证） |
| `停止监控.bat` | 停止后台监控 |
| `logs/` | 运行日志（自动生成） |
| `debug/` | 认证页 / 响应抓包（自动生成，排查失败用） |
| `test/` | 本地端到端测试（假门户，不访问真实校园网） |

## 工作原理

1. **判断是否需要认证**：访问连通性检测地址（如 `msftconnecttest.com`）。正常应返回 `Microsoft Connect Test`；若被 302 重定向或内容被替换，说明撞上了强制门户，同时从重定向地址里取出本机当时的 `wlanuserip` / `wlanacname`。
2. **获取一次性认证参数**：`GET /PortalJsonAction.do` 换取本次认证所需的 `timestamp` / `uuid` / `serverip` 等挑战参数。
3. **拼接运营商后缀**：账号按所选运营商追加后缀（如电信账号为 `学号@gxydx`）。
4. **提交认证**：`GET /quickauth.do` 携带全部参数完成认证，读取响应中的 `code` 判断结果。
5. **复检网络**：等待 `wait_seconds` 秒后再次访问检测地址，确认已联网；失败则按配置重试。

## 配置项详解（config.json）

```jsonc
{
  "account":  "你的学号",          // 账号
  "password": "你的密码",          // 密码（必填）
  "isp": "telecom",               // 账号类型: local 校园网本地 / mobile 移动 / unicom 联通 / telecom 电信
  "isp_suffix": {                  // 各账号类型的后缀（一般保持默认即可）
    "local":   "@gxylocal",
    "mobile":  "@gxyyd",
    "unicom":  "@gxylt",
    "telecom": "@gxydx"
  },
  "wait_seconds": 5,               // 登录后等待多少秒再验证网络
  "retries": 3,                    // 认证失败最多重试几次
  "retry_delay_seconds": 3,        // 每次重试间隔
  "timeout_seconds": 10,           // 单个 HTTP 请求超时（秒）
  "check_interval_seconds": 3,     // 【监控模式】每几秒检查一次网络状态变化
  "periodic_check_seconds": 300,   // 【监控模式】即使无变化，每 N 秒也复检一次（0 = 关闭）
  "portal_fallback_url": "...",    // 抓不到重定向时的备用认证地址（一般用不到）
  "form_extra_fields": {},         // 需额外提交的字段，如 {"ac_id": "1"}
  "debug": true                    // 保存认证页 / 响应到 debug/ 目录
}
```

### 切换运营商

把 `isp` 改成 `local` / `mobile` / `unicom` / `telecom` 之一即可，无需重启，后台监控每次登录都会重新读取配置。

## 常见问题

**Q: 会一直弹黑窗口吗？**
用 `启动后台监控.vbs` 启动则完全无窗口；`立即登录.bat` 是手动工具，会显示过程。

**Q: 开机自动运行？**
Win+R 输入 `shell:startup`（提示需要管理员权限可以输入 'shell:common startup' )回车，把 `启动后台监控.vbs` 的快捷方式放进去。

**Q: 监控是不是一直在发网络请求？**
状态检查是读本机 IP / SSID（零流量）；只有状态变化或到达复检周期时才发 1~3 个很小的探测请求。

**Q: 密码明文保存安全吗？**
`config.json` 只在你本机，注意不要把整个文件夹发给别人。仓库已通过 `.gitignore` 排除日志与抓包等运行时产物。

**Q: 提示"未能在认证页面中找到密码输入框"？**
说明门户返回的不是预期页面（改版或异常）。把 `debug/` 目录下最新的 `login_page_*.html` 发给维护者分析即可。

**Q: 双击 bat 提示"禁止运行脚本"？**
属系统执行策略限制。bat 已内置 `-ExecutionPolicy Bypass`，一般不会触发；若仍被拦，右键选择"使用 PowerShell 运行"。

## 本地测试

`test/` 内含一个复刻门户结构的假门户，可在不连接校园网的情况下验证请求构造：

```powershell
# 终端 1：启动假门户
powershell -ExecutionPolicy Bypass -File test\fake_portal.ps1

# 终端 2：跑一次认证（应返回 code=0）
powershell -ExecutionPolicy Bypass -File autologin.ps1 -Mode once -ConfigPath test\config_test.json
```

## 兼容性

- Windows 10 / 11
- Windows PowerShell 5.1+（系统自带，无需安装）
- 适用于锐捷 Portal 认证体系（`PortalJsonAction.do` + `quickauth.do`）的校园网

## 免责声明

本工具仅供学习交流使用，请遵守所在学校的网络使用规定。因使用本工具造成的一切后果由使用者自行承担。
部分内容由AI生成。

## License

MIT
