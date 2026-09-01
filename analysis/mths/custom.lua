-- custom.lua
-- 用户自定义事件脚本，点击悬浮菜单"用户事件"按钮时执行
-- 运行在独立 LuaJ 虚拟机中，与主脚本引擎隔离

local Looper = luajava.bindClass("android.os.Looper")
local Handler = luajava.bindClass("android.os.Handler")
local Toast = luajava.bindClass("android.widget.Toast")

if Looper:myLooper() == nil then
    Looper:prepare()
end

pcall(function() service:registerLooper(Looper:myLooper()) end)

local handler = luajava.newInstance("android.os.Handler", Looper:myLooper())

Toast:makeText(context, "Hello from custom.lua!", Toast.LENGTH_SHORT):show()

handler:postDelayed(luajava.createProxy("java.lang.Runnable", {
    run = function()
        Looper:myLooper():quit()
    end
}), 3000)

Looper:loop()

return "ok"
