
local oo            = require("loop.simple")

local AppletMeta    = require("jive.AppletMeta")
local jul           = require("jive.utils.log")

local appletManager = appletManager
local jiveMain      = jiveMain


module(...)
oo.class(_M, AppletMeta)


function jiveVersion(meta)
	return 1, 1
end


function defaultSettings(meta)
	return { 
		brightness = 32,
		dimmedTimeout = 10000,
		sleepTimeout = 60000,
		hibernateTimeout = 300000,
		dimmedAC = false
	}
end


function registerApplet(meta)
	jul.addCategory("squeezeboxJive", jul.DEBUG)

	-- SqueezeboxJive is a resident Applet
	appletManager:loadApplet("SqueezeboxJive")

	local remoteSettings = jiveMain:subMenu(meta:string("SETTINGS")):subMenu(meta:string("REMOTE_SETTINGS"))
	local advancedSettings = remoteSettings:subMenu(meta:string("ADVANCED_SETTINGS"))

	remoteSettings:addItem(meta:menuItem("BSP_BRIGHTNESS", function(applet, ...) applet:settingsBrightnessShow(...) end))
	remoteSettings:addItem(meta:menuItem("BSP_BACKLIGHT_TIMER", function(applet, ...) applet:settingsBacklightTimerShow(...) end))
	advancedSettings:addItem(meta:menuItem("POWER_DOWN", function(applet, ...) applet:settingsPowerDown(...) end))
end


--[[

=head1 LICENSE

Copyright 2007 Logitech. All Rights Reserved.

This file is subject to the Logitech Public Source License Version 1.0. Please see the LICENCE file for details.

=cut
--]]

