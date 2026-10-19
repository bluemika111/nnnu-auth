-- 校园网认证 — LuCI 菜单与路由
module("luci.controller.nnnu-auth", package.seeall)

function index()
	entry({"admin", "services", "nnnu-auth"}, firstchild(), _("校园网认证"), 60).dependent = false

	entry({"admin", "services", "nnnu-auth", "settings"}, cbi("nnnu-auth/settings"), _("设置"), 10)
	entry({"admin", "services", "nnnu-auth", "status"}, template("nnnu-auth/status"), _("状态与诊断"), 20)

	-- 动作落地页: 只给状态页的按钮用, 不进标签菜单。
	-- 踩过的坑: 把它作为一个带标题的 entry 注册, 菜单里会多出一个「执行」标签,
	-- 点进去没有动作参数, 于是显示「不支持的指令」。所以这里 title 留空 + leaf = true,
	-- 动作名走路径的最后一段 (.../action/login), 不依赖 query string。
	local act = entry({"admin", "services", "nnnu-auth", "action"},
		template("nnnu-auth/action"), nil)
	act.leaf = true
	act.dependent = false

	local _, a
	for _, a in ipairs({"login", "ensure", "status", "doctor", "logout"}) do
		local e = entry({"admin", "services", "nnnu-auth", "action", a},
			template("nnnu-auth/action"), nil)
		e.leaf = true
		e.dependent = false
	end
end
