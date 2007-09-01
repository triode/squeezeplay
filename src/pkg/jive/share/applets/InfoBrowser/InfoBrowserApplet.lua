
--[[
=head1 NAME

Info Browser Applet

=head1 DESCRIPTION

Browser for information sources using the Slimserver InfoBrowser plugin.

=cut
--]]

-- stuff we use
local pairs, tonumber, tostring = pairs, tonumber, tostring

local oo            = require("loop.simple")
local table         = require("table")
local string        = require("string")

local Applet        = require("jive.Applet")
local SlimServers   = require("jive.slim.SlimServers")

local AppletManager = require("jive.AppletManager")

require("jive.slim.RequestsCli")
local RequestCli    = jive.slim.RequestCli

local Framework     = require("jive.ui.Framework")
local SimpleMenu    = require("jive.ui.SimpleMenu")
local Window        = require("jive.ui.Window")
local Textarea      = require("jive.ui.Textarea")
local Popup         = require("jive.ui.Popup")
local Timer         = require("jive.ui.Timer")

local EVENT_KEY_PRESS  = jive.ui.EVENT_KEY_PRESS
local EVENT_CONSUME    = jive.ui.EVENT_CONSUME
local EVENT_UNUSED     = jive.ui.EVENT_UNUSED
local KEY_ADD          = jive.ui.KEY_ADD
local KEY_PLAY         = jive.ui.KEY_PLAY

local log           = require("jive.utils.log").logger("applets.misc")
local debug         = require("jive.utils.debug")


module(...)
oo.class(_M, Applet)


local gulp    = 20     -- get this many entries per request


-- open main menu
function menu(self, menuItem)

	local list = {}
	local window = Window("window", menuItem.text)
	local menu = SimpleMenu("menu", list)
	window:addWidget(menu)

	self:tieAndShowWindow(window)

	-- find server for current player and send first request
	sd = AppletManager:getAppletInstance("SlimDiscovery")
	if sd and sd:getCurrentPlayer() then
		self.server = sd:getCurrentPlayer():getSlimServer()
		self:request(nil, 0, window, menu, list)
	end
end


-- request for items
function request(self, index, start, window, widget, list, prevmenu, locked)

	local req = RequestCli(
		function(chunk, err)
			if err then
				log:debug(err)
			elseif chunk then
				self:response(chunk.result, window, widget, list, prevmenu, locked)
			end
		end,
		false,
		{'infobrowser', 'items'}, start, gulp, index and { item_id = index }
	)

	self.server:queuePriority(req)
end


-- sink to process response and display items
function response(self, result, window, widget, list, prevmenu, locked)

	local id

	-- end previous menu animation and show new window
	if locked then
		prevmenu:unlock()
		window:show()
	end

	-- itterate though response - handle leaves as well as branches
	for _,entry in pairs(result.loop_loop) do
		id = entry.id
		if entry.hasitems then
			-- branch - add menu entry for this item
			list[#list + 1] = {
				text = entry.name or entry.title,
				callback = function(_, menuItem)
							   local newlist = {}
							   local newwindow = Window("window", menuItem.text)
							   -- assume new level is a menu for the moment, this is replaced later if it is not
							   local newmenu = SimpleMenu("menu", newlist)
							   newwindow:addWidget(newmenu)
							   widget:lock()
							   self:request(entry.id, 0, newwindow, newmenu, newlist, widget, true)
						   end
			}
		elseif entry.description then
			-- leaf - update textarea page for this item or replace menu with textarea and update
			window:setTitle(entry.name or entry.title)
			if oo.instanceof(widget, SimpleMenu) then
				window:removeWidget(widget)
				widget = Textarea("textarea")
				window:addWidget(widget)
			end
			widget:setText(entry.description)
			widget:addListener(EVENT_KEY_PRESS,
				function(event)
					local key = event:getKeycode()
					if key ~= KEY_ADD and key ~= KEY_PLAY then
						return EVENT_UNUSED
					end
					local pre, c = _split(id)
					if key == KEY_PLAY and c+1 < prevmenu.listSize then
						c = c + 1
					elseif key == KEY_ADD and c > 0 then
						c = c - 1
					else
						window:bumpRight()
					end
					-- fetch next item and update index on previous menu to match
					self:request(pre .. "." .. tostring(c), 0, window, widget, list, prevmenu)
					prevmenu:setSelectedIndex(c+1)
					return EVENT_CONSUME
				end)
		end
	end

	-- handle fetching rest of level if it is larger than one gulp
	if #list > 0 then
		widget:setItems(list)
		local pre, c = _split(id)
		if c < result.count - 1 then
			self:request(pre, c + 1, window, widget, list, prevmenu)
		end
	end
end


-- split cli index into prefix and index for this level
function _split(index)
	local t = {}
	for i in string.gmatch(index or "", "[0-9]+") do
		t[#t+1] = i
	end
	local c = t[#t]
	t[#t] = nil
	local pre = table.concat(t, ".")
	return pre, tonumber(c)
end

