
--[[
=head1 NAME

applets.SetupWallpaper.SetupWallpaperApplet - Wallpaper selection.

=head1 DESCRIPTION

This applet implements selection of the wallpaper for the jive background image.

The applet includes a selection of local wallpapers which are shipped with jive. It
also allows wallpapers to be downloaded and selected from the currently  attached server.

=head1 FUNCTIONS

Applet related methods are described in L<jive.Applet>. 
SetupWallpaperApplet overrides the following methods:

=cut
--]]


-- stuff we use
local ipairs, pairs, type, print, tostring = ipairs, pairs, type, print, tostring

local oo                     = require("loop.simple")
local io                     = require("io")
local table                  = require("jive.utils.table")
local string                 = require("jive.utils.string")

local Applet                 = require("jive.Applet")
local System                 = require("jive.System")
local Framework              = require("jive.ui.Framework")
local RadioButton            = require("jive.ui.RadioButton")
local RadioGroup             = require("jive.ui.RadioGroup")
local SimpleMenu             = require("jive.ui.SimpleMenu")
local Textarea               = require("jive.ui.Textarea")
local Tile                   = require("jive.ui.Tile")
local Window                 = require("jive.ui.Window")
local Framework              = require("jive.ui.Framework")

local RequestHttp            = require("jive.net.RequestHttp")
local SocketHttp             = require("jive.net.SocketHttp")

local debug                  = require("jive.utils.debug")

local jnt                    = jnt
local appletManager          = appletManager
local jiveMain               = jiveMain

module(..., Framework.constants)
oo.class(_M, Applet)


local authors = { "Chapple", "Scott Robinson", "Los Cardinalos", "Orin Optiglot", "Ryan McD", "Robbie Fisher" }

local firmwarePrefix = "applets/SetupWallpaper/wallpaper/"
local downloadPrefix


function init(self)
	jnt:subscribe(self)

	downloadPrefix = System.getUserDir().. "/wallpapers"
	appletManager._mkdirRecursive(downloadPrefix)
	downloadPrefix = downloadPrefix .. "/"

	log:debug("downloaded wallpapers stored at: ", downloadPrefix)

	self.download = {}
	self.wallpapers = {}
end

-- notify_playerCurrent
-- this is called when the current player changes (possibly from no player)
function notify_playerCurrent(self, player)
	log:debug("SetupWallpaper:notify_playerCurrent(", player, ")")
	if player == self.player then
		return
	end

	self.player = player
	if player and player:getId() then
		self:setBackground(nil, player:getId())
	else
		self:setBackground(nil, 'wallpaper')
	end
end


function settingsShow(self)
	local window = Window("text_list", self:string('WALLPAPER'), 'settingstitle')

	-- default is different based on skin
	self.currentPlayerId = jiveMain:getSelectedSkin()

	local _playerName    = false

	if not self.player then
		self.player = appletManager:callService("getCurrentPlayer")
	end

	if self.player then
		self.currentPlayerId = self.player:getId()
		self.playerName    = self.player:getName()
	end

	self.menu = SimpleMenu("menu")
	window:addWidget(self.menu)

	local wallpaper = self:getSettings()[self.currentPlayerId]

	self.server = self:_getCurrentServer()

	self.group  = RadioGroup()

	self.menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
	
	local screenWidth, screenHeight = Framework:getScreenSize()
	log:warn(screenWidth, '|', screenHeight)

	-- read all files in the wallpaper/ directory and into self.wallpapers
	-- this step is done first so images aren't read twice, 
	-- once from source area and once from build area
	for img in self:readdir("wallpaper") do
		-- split the fullpath into a table on /
		local fullpath = string.split('/', img)
		-- the filename is the last element in the fullpath table
		local name = fullpath[#fullpath]
		-- split on the period to get filename and filesuffix
		local parts = string.split("%.", name)

		-- if the suffix represents an image format (see _isImg() method), translate and add to the menu
		if self:_isImg(parts[2]) then
			-- token is represented by uppercase of the filename
			local splitFurther = string.split("_", parts[1])
			local stringToken = string.upper(splitFurther[#splitFurther])
			local patternMatch = string.upper(parts[1])

			-- limit self.wallpapers when screenWidth and screenHeight are certain parameters
			local pattern = nil
			if screenWidth == 320 and screenHeight == 240 then
				pattern = 'BB_'
			elseif screenWidth == 240 and screenHeight == 320 then
				pattern = 'JIVE_'
			elseif screenWidth == 480 and screenHeight == 272 then
				pattern = 'FAB4_'
			end

			if not self.wallpapers[name] and ( not pattern or ( pattern and string.match(patternMatch, pattern) ) ) then
				self.wallpapers[name] = {
					token    = stringToken,
					suffix   = parts[2],
					fullpath = fullpath,
				}
			end
		end
	end

	for name, details in pairs(self.wallpapers) do
		log:warn(name, "|", details.token)
			self.menu:addItem({
				-- anything local goes to the top 
				-- (i.e., higher precendence than SC-delivered custom wallpaper)
				weight = 1,
				text = self:string(details.token), 
				style = 'item_choice',
				sound = "WINDOWSHOW",
				check = RadioButton("radio", 
						   self.group, 
						   function()
							   self:setBackground(name, self.currentPlayerId)
						   end,
						   wallpaper == img
					   ),
				focusGained = function(event)
						  self:showBackground(name, self.currentPlayerId)
					  end
			})

			if wallpaper == name then
				self.menu:setSelectedIndex(self.menu:numItems())
			end

		end

	local x, y = Framework:getScreenSize()
	local screen = x .. "x" .. y
	if screen ~= "480x272" and screen ~= "240x320" and screen ~= "320x240" then
		screen = nil
	end


	if screen == '240x320' then
		self.menu:addItem(self:_licenseMenuItem())
	end

	-- get list of downloadable wallpapers from the server
	if self.server then

		log:debug("found server - requesting wallpapers list ", screen)

		self.server:userRequest(
			function(chunk, err)
				if err then
					log:debug(err)
				elseif chunk then
					self:_serverSink(chunk.data)
				end
			end,
			false,
			screen and { "jivewallpapers", "target:" .. screen } or { "jivewallpapers" }
		)
	end

	-- Store the applet settings when the window is closed
	window:addListener(EVENT_WINDOW_POP,
		function()
			self:showBackground(nil, self.currentPlayerId)
			self:storeSettings()
			self.download = {}
		end
	)

	self:tieAndShowWindow(window)
	return window
end

-- returns true if suffix string is for an image format file extention
function _isImg(self, suffix)
	if suffix == 'png' or suffix == 'jpg' or suffix == 'gif' then
		return true
	end

	return false
end


function _getCurrentServer(self)

	local server
	if self.player then
		server = self.player:getSlimServer()
	else
		for _, s in appletManager:callService("iterateSqueezeCenters") do
			server = s
			break
		end
	end

	return server
end


function _serverSink(self, data)

	local ip, port = self.server:getIpPort()

	local wallpaper = self:getSettings()[self.currentPlayerId]

	if data.item_loop then
		for _,entry in pairs(data.item_loop) do
			local url
			if entry.relurl then
				url = 'http://' .. ip .. ':' .. port .. entry.relurl
			else
				url = entry.url
			end
			log:debug("remote wallpaper: ", entry.title, " ", url)
			self.menu:addItem(
				{
					weight = 50,	  
					text = entry.title,
					style = 'item_choice',
					check = RadioButton("radio",
									   self.group,
									   function()
										   if self.download[url] then
											   self:setBackground(url, self.currentPlayerId)
										   end
									   end,
									   wallpaper == url
								   ),
					focusGained = function()
									  if self.download[url] and self.download[url] ~= "fetch" and self.download[url] ~= "fetchset" then
										  log:debug("using cached: ", url)
										  self:showBackground(url, self.currentPlayerId)
									  else
										  self:_fetchFile(url, 
														  function(set) 
															  if set then
																  self:setBackground(url, self.currentPlayerId)
															  else
																  self:showBackground(url, self.currentPlayerId)
															  end
														  end )
									  end
								  end
				}
			)
			if wallpaper == url then
				self.menu:setSelectedIndex(self.menu:numItems() - 1)
			end
		end
	end
end


function _licenseMenuItem(self)
	return {
		weight = 99,
		text = self:string("CREDITS"),
		sound = "WINDOWSHOW",
		callback = function()
			local window = Window("text_list", self:string("CREDITS"))
			
			local text =
				tostring(self:string("CREATIVE_COMMONS")) ..
				"\n\n" ..
				tostring(self:string("CREDITS_BY")) ..
				"\n " ..
				table.concat(authors, "\n ")

			window:addWidget(Textarea("text", text))
			self:tieAndShowWindow(window)
		end,
		focusGained = function(event) self:showBackground(nil, self.currentPlayerId) end
	}
end


function _fetchFile(self, url, callback)
	self.last = url

	if self.download[url] then
		log:warn("already fetching ", url, " not fetching again")
		return
	else
		log:debug("fetching background: ", url)
	end
	self.download[url] = "fetch"

	-- FIXME
	-- need something here to contrain size of self.download

	local req = RequestHttp(
		function(chunk, err)
			if err then
				log:warn("error fetching background: ", url)
				self.download[url] = nil
			end
			local state = self.download[url]
			if chunk and (state == "fetch" or state == "fetchset") then
				log:debug("fetched background: ", url)
				self.download[url] = chunk
	
				if url == self.last then
					callback(state == "fetchset")
				end
			end
		end,
		'GET',
		url
	)

	local uri  = req:getURI()
	local http = SocketHttp(jnt, uri.host, uri.port, uri.host)

	http:fetch(req)
end


function showBackground(self, wallpaper, playerId)

	-- default is different based on skin
	local skinName = jiveMain:getSelectedSkin()
	if not playerId then playerId = skinName end

	if not wallpaper then
		wallpaper = self:getSettings()[playerId]
		if not wallpaper then
			wallpaper = self:getSettings()[skinName]
		end
	end
	if self.currentWallpaper == wallpaper then
		-- no change
		return
	end
	self.currentWallpaper = wallpaper

	local srf
	if self.download[wallpaper] then
		-- image in download cache
		if self.download[wallpaper] ~= "fetch" and self.download[url] ~= "fetchset" then
			local data = self.download[wallpaper]
			srf = Tile:loadImageData(data, #data)
		end
	elseif string.match(wallpaper, "http://(.*)") then
		-- saved remote image for this player
		srf = Tile:loadImage(downloadPrefix .. playerId:gsub(":", "-"))
	else
		-- try firmware wallpaper
		srf = Tile:loadImage(firmwarePrefix .. wallpaper)
	end
	if srf ~= nil then
		Framework:setBackground(srf)
	end
end


function setBackground(self, wallpaper, playerId)
	if not playerId then 
		-- default is different based on skin
		playerId = jiveMain:getSelectedSkin()
	end

	log:debug('SetupWallpaper, setting wallpaper for ', playerId)

	-- set the new wallpaper, or use the existing setting
	if wallpaper then

		if self.download[wallpaper] then
			if self.download[wallpaper] == "fetch" then
				self.download[wallpaper] = "fetchset"
				return
			end
			local path = downloadPrefix .. playerId:gsub(":", "-")
			local fh = io.open(path, "wb")
			if fh then
				log:debug("saving image to ", path)
				fh:write(self.download[wallpaper])
				fh:close()
			else
				log:warn("unable to same image to ", path)
			end
		end

		self:getSettings()[playerId] = wallpaper
	end

	self:showBackground(wallpaper, playerId)
end


--[[

=head1 LICENSE

Copyright 2007 Logitech. All Rights Reserved.

This file is subject to the Logitech Public Source License Version 1.0. Please see the LICENCE file for details.

=cut
--]]

