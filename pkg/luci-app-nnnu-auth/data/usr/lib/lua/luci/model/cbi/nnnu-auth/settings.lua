-- 校园网认证 — 设置页
--
-- 这里刻意只用最保守的 CBI 写法: NamedSection + option, 不用 tabs。
-- 踩过的坑: 写 `s.tabs = true` 再 `s:tab()` 会直接让页面崩掉 ——
-- LuCI 的 AbstractSection.tab() 内部是 `self.tabs = self.tabs or { }`,
-- 先赋成布尔值 true 就会保留下来, 接着被当表用:
--   /usr/lib/lua/luci/cbi.lua:844: attempt to index a boolean value
-- 正确用法是什么都不设, 只用 s:tab(name, title) 让它自己建表;
-- 这里干脆用多个 NamedSection 分组, 连 tabs 都不依赖。

local m, s, o

-- 显式 require: CBI 模型文件里 luci.sys 不一定已经加载好
local sys = require "luci.sys"

m = Map("nnnu-auth", translate("校园网认证"),
	translate("自动登录校园网门户并保持在线。密码以明文保存在 /etc/config/nnnu-auth（权限 600），" ..
		"请确保只有本人能登录这台路由器。"))

m.on_after_commit = function()
	-- 保存后立刻渲染配置并切换运行方式
	sys.exec("/usr/share/nnnu-auth/apply.sh >/tmp/nnnu-auth-apply.log 2>&1")
end

-- ------------------------------------------------------------------ 基本设置
s = m:section(NamedSection, "main", "auth", translate("基本设置"))
s.addremove = false

o = s:option(Flag, "enabled", translate("启用自动认证"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "username", translate("学号 / 账号"))
o.datatype = "string"
o.rmempty = false
o.placeholder = "2024000001"

o = s:option(Value, "password", translate("密码"))
o.password = true
o.rmempty = false

o = s:option(ListValue, "mode", translate("运行方式"),
	translate("二选一即可，apply 时会自动把另一种关掉"))
o:value("cron", translate("cron 每分钟检查（省内存，推荐）"))
o:value("service", translate("procd 常驻守护（掉线恢复更快）"))
o.default = "cron"

o = s:option(Flag, "bind_mac", translate("提交时绑定 MAC"),
	translate("与浏览器里勾选「绑定MAC」等价；账号只想在这台路由器上用就勾上"))
o.default = "1"

o = s:option(Flag, "remember", translate("提交时勾选「记住密码」"))
o.default = "1"

-- ------------------------------------------------------------------ 高级设置
s = m:section(NamedSection, "main", "auth", translate("高级设置"))

o = s:option(Value, "interval", translate("检查间隔（秒）"),
	translate("cron 模式下的最小粒度是 60 秒"))
o.datatype = "uinteger"
o.default = "60"

o = s:option(Value, "dial_wait", translate("等待代拨结果（秒）"))
o.datatype = "uinteger"
o.default = "60"

o = s:option(Value, "verify_wait", translate("等待真正联网（秒）"))
o.datatype = "uinteger"
o.default = "60"

o = s:option(Value, "timeout", translate("单次 HTTP 超时（秒）"))
o.datatype = "uinteger"
o.default = "8"

o = s:option(TextValue, "probe_urls", translate("探测地址"),
	translate("未认证时这些地址会被网关劫持并跳转到门户，认证后返回 204。用空格分隔多个。"))
o.rows = 3
o.wrap = "off"

o = s:option(ListValue, "http_client", translate("HTTP 客户端"))
o:value("auto", translate("自动（优先 curl）"))
o:value("curl", "curl")
o:value("uclient-fetch", "uclient-fetch")
o:value("wget", "wget")
o.default = "auto"

o = s:option(ListValue, "hextool", translate("URL 编码器"),
	translate("留空自动探测。若日志出现「URL 编码自检失败」，手动选 awk 即可。"))
o:value("", translate("自动探测"))
o:value("od", "od")
o:value("hexdump", "hexdump")
o:value("awk", "awk（纯 awk 兜底）")
o.default = ""

o = s:option(Value, "log_file", translate("日志文件"))
o.default = "/var/log/nnnu-auth.log"

-- ---------------------------------------------------- 门户参数（一般不用改）
s = m:section(NamedSection, "main", "auth", translate("门户参数（一般不用改）"))

o = s:option(Value, "portal_host", translate("门户地址"))
o.default = "172.27.0.5"

o = s:option(Value, "wlanacname", translate("网关(BRAS)名称"))
o.default = "ZAXSOFT-BRAS-WM"

o = s:option(Value, "wlanacip", translate("网关(BRAS)地址"))
o.default = "172.27.0.100"

o = s:option(Value, "default_url", translate("兜底原始 URL"),
	translate("只有抓不到网关 302 时才用得到"))

o = s:option(Value, "wan_iface", translate("WAN 接口（留空自动）"))
o.placeholder = "eth1"

o = s:option(Value, "wan_mac", translate("WAN MAC（留空自动）"))
o.placeholder = "11:22:33:44:55:66"

o = s:option(Value, "wan_ip", translate("WAN IP（留空自动）"))

return m
