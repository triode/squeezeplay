local load, ipairs, pairs, type, tostring, tonumber  = load, ipairs, pairs, type, tostring, tonumber

-- stuff we use
local math             = require("math")
local json             = require("json")
local table            = require("jive.utils.table")
local string           = require("jive.utils.string")
local debug            = require("jive.utils.debug")

local oo                     = require("loop.simple")
local io                     = require("io")
local os                     = require("os")

local Applet                 = require("jive.Applet")
local Framework              = require("jive.ui.Framework")
local Icon                   = require("jive.ui.Icon")
local Label                  = require("jive.ui.Label")
local Popup                  = require("jive.ui.Popup")
local SimpleMenu             = require("jive.ui.SimpleMenu")
local Textarea               = require("jive.ui.Textarea")
local Task                   = require("jive.ui.Task")
local Timer                  = require("jive.ui.Timer")
local Window                 = require("jive.ui.Window")

local appletManager          = appletManager


local MOUNTING_DRIVE_TIMEOUT = 30

local _supportedFormats = {"FAT16","FAT32","NTFS","ext2","ext3"}

module(..., Framework.constants)
oo.class(_M, Applet)


function settingsShow(self, menuItem)
	local window = Window("text_list", menuItem.text, 'settingstitle')
	
	-- XXX: first attempt at showing scan process running
	self.status = Textarea("help_text", self:_getStatusText() )

	local menu = SimpleMenu("menu", {
					{
						text = self:string("START"),
						sound = "WINDOWSHOW",
						callback = function()
								   self:_action("icon_connecting", "STARTING_SQUEEZECENTER", "STARTING_SQUEEZECENTER_TEXT", 5000, "start")
							   end
					},
					{
						text = self:string("STOP"),
						sound = "WINDOWSHOW",
						callback = function()
								   self:_action("icon_connecting", "STOPPING_SQUEEZECENTER", nil, 2000, "stop")
							   end
					},
					{
						text = self:string("STOP_RESCAN_START"),
						sound = "WINDOWSHOW",
						callback = function()
								   self:_action("icon_connected", "RESCAN_SQUEEZECENTER", "RESCAN_SQUEEZECENTER_TEXT", 10000, "rescan")
							   end
					},
				})

	menu:setHeaderWidget(self.status)
	window:addWidget(menu)

	self:tieAndShowWindow(window)
	
	window:addTimer(5000, function() _updateStatus(self) end)
	
	return window
end

function _action(self, icon, text, subtext, time, action)

	-- Check validity of action
	if (action == 'start' and (_pidfor('slimserver.pl') or _pidfor('scanner.pl'))
		or action == 'stop' and not _pidfor('slimserver.pl')
		or action == 'rescan' and _pidfor('scanner.pl'))
	then
		return EVENT_UNUSED
	end

	local popup = Popup("waiting_popup")
	popup:addWidget(Icon(icon))
	popup:addWidget(Label("text", self:string(text)))
	
	if (subtext ~= nil) then popup:addWidget(Textarea("subtext", self:string(subtext))) end
	
	popup:showBriefly(time,
		function()
			_updateStatus(self)
		end,
		Window.transitionPushPopupUp,
		Window.transitionPushPopupDown
	)

	os.execute("/etc/init.d/squeezecenter " .. action);

end

function _getStatusText(self)
	-- XXX: first attempt at showing scan process running
	local statusText
	if self:scannerRunning() then
		self.scannerStatus = self:_scanStatus()
		statusText = self:_scanProgressText()
		log:debug(statusText)
	else
		statusText = self:string( self:_getStatus() )
	end
	return statusText
end


function _updateStatus(self)
	self.status:setValue( self:_getStatusText() )
end


-- udevHandler takes events on udev and decides whether and when to kick off the scanner
function udevEventHandler(self, evt, msg)

	log:warn('udevEventHandler()', msg)

	-- work in progress: useful for viewing what's in the msg table
	for k, val in pairs(msg) do
		log:warn('key: ', k, ' val: ', val)
	end

	-- if the ACTION in the msg is add and DEVTYPE is partition
	-- 	bring up a spinny "Checking Drive..."
	--	we should start polling mount to see if a drive gets mounted rw
	--	if it does, hide the popup, start the scanner (/etc/init.d/squeezecenter rescan), and push to the SqueezeCenter menu
	--	if it doesn't, popup an appropriate error
	if msg and msg.ACTION == 'add' and msg.DEVTYPE == 'partition' then
		local devPath = msg.DEVPATH
		-- Extract device name (last element)
		local pathElements = string.split('/', devPath)
		local devName = pathElements[#pathElements]

		log:debug("Device name: ", devName)

--		self:_mountingDrive(devName)
	end
end


-- _mountingDrive
-- full screen popup that appears until mounting is complete or failed
---function _mountingDrive(self)
function _mountingDrive(self, devName)
	log:warn('**** popup during drive mount')
	if self.popupWaiting then
		return
	end

        local popup = Popup("waiting_popup")
        local icon  = Icon("icon_connecting")

	self.mountingDriveTimeout = 0

	icon:addTimer(1000,
		function()
			_mountingDriveTimer(self, devName)
		end)

        popup:addWidget(icon)
	local label = Label("text", self:string('ATTACHING_DRIVE'))
	popup:addWidget(label)
	self.popupWaiting = popup
	self:tieAndShowWindow(popup)
end


function _mountingDriveTimer(self, devName)
	local mounted = false

	Task("mountingDrive", self, function()
		log:debug("mountingDriveTimeout=", self.mountingDriveTimeout)

		mounted = self:_checkDriveMounted(devName)

		if mounted then
			-- success
			log:debug("*** Device mounted sucessfully.")

			self:_ejectWarning()
		else
			-- Not yet mounted
			self.mountingDriveTimeout = self.mountingDriveTimeout + 1
			if self.mountingDriveTimeout <= MOUNTING_DRIVE_TIMEOUT then
				return
			end

			-- failure
			log:debug("*** Device failed to mount.")

			self:_unsupportedDiskFormat()
		end

		self.popupWaiting:hide()
		self.popupWaiting = nil

	end):addTask()
end


function _checkDriveMounted(self, devName)
	local format = nil
	local mount = io.popen("/bin/mount")

	for line in mount:lines() do
		local dummy = string.match(line, "/dev/" .. devName)
		if dummy then
			format = string.match(line, "type (%w*)")
		end
	end
	mount:close()

	if format then
		log:warn("New device: /dev/", devName, " formatted with: ", format)
		return true
	end

	return false
end


-- Not supported disk format error message
function _unsupportedDiskFormat(self)
	local window = Window("text_list", self:string("UNSUPPORTED_DISK_FORMAT"))
	window:setAllowScreensaver(false)
	window:setButtonAction("rbutton", nil)

	local menu = SimpleMenu("menu")

	menu:addItem({
		text = self:string("OK"),
		style = 'item',
		sound = "WINDOWSHOW",		
		callback = function ()
			window:hide()
		end
	})

	local formats = ""
	for i = 1, (#_supportedFormats - 1) do
		formats = formats .. _supportedFormats[i] .. ", "
	end
	formats = formats .. _supportedFormats[#_supportedFormats]

	menu:setHeaderWidget(Textarea("help_text", self:string("UNSUPPORTED_DISK_FORMAT_INFO", formats)))

	window:addWidget(menu)

	self:tieAndShowWindow(window)
	return window
end


-- Ejection Warning for new USB/SD drives
function _ejectWarning(self)
	local window = Window("text_list", self:string("EJECT_WARNING"))
	window:setAllowScreensaver(false)
	window:setButtonAction("rbutton", nil)

	local menu = SimpleMenu("menu")

	menu:addItem({
		text = self:string("OK"),
		style = 'item',
		sound = "WINDOWSHOW",		
		callback = function ()
-- TODO: continue in the flow
			window:hide()
		end
	})

	menu:setHeaderWidget(Textarea("help_text", self:string("EJECT_WARNING_INFO")))

	window:addWidget(menu)

	self:tieAndShowWindow(window)
	return window
end


function serverRunning(self)
	local sc = _pidfor('slimserver.pl')
	if (sc ~= nil) then
		return true
	end
	return false
end


function scannerRunning(self)
	local scanner = _pidfor('scanner.pl')
	if (scanner ~= nil) then
		return true
	end
	return false
end


function _getStatus(self)
	if self:serverRunning() then
		return "STATUS_SQUEEZECENTER_RUNNING"
	elseif self:scannerRunning() then
		return "STATUS_SCANNER_RUNNING"
	else
		return "STATUS_NOTHING"
	end
end


function _pidfor(process)
	local pid

	local pattern = "%s*(%d+).*" .. process

	log:debug("pattern is ", pattern)

	local cmd = io.popen("/bin/ps -o pid,command")
	for line in cmd:lines() do
		pid = string.match(line, pattern)
		if pid then break end
	end
	cmd:close()

	return pid
end


function _scanStatus(self)

	log:debug("_scanStatus()")
	local scanStatus = {}

	local file = "/etc/squeezecenter/scan.json"
	local fh = io.open(file, "r")

        if fh == nil then
		-- no scan file present
		return false
        end

	local jsonData = fh:read("*all")
	fh:close()

	scanStatus = json.decode(jsonData)
	return scanStatus
end


-- uses self.scannerStatus table and returns a formatted text block for informational display
function _scanProgressText(self)

	local runningText   = self:string('RUNNING')
	local completedText = self:string('COMPLETE')
	local hasData       = false

	if self.scannerStatus then
		local progressReport = {}
		-- self.scannerStatus is an array of scanner steps
		for i, step in ipairs(self.scannerStatus) do
			-- without a step.name, don't report anything
			if step.name then
				hasData = true
				local token = string.upper(step.name) .. '_PROGRESS'
				local nameString = self:string(token)

				-- first line is the name of the step and the status of it (completed or running)
				if step.finish and type(step.finish) == 'number' and step.finish > 0 then
					local completed = tostring(nameString) .. ": " .. tostring(completedText)
					table.insert(progressReport, completed)
				else
					local running = tostring(nameString) .. ": " .. tostring(runningText)
					table.insert(progressReport, running)
				end
				
				--- second line is detailed info on the step
				local secondLineTable = {}
				if step.done and step.total then
					local percentageDone = tostring(math.floor( 100 * tonumber(step.done)/tonumber(step.total)))
					local percentageString = tostring(completedText) .. ": " .. percentageDone .. "%"
					local xofy = "(" .. tostring(step.done) .. '/' .. tostring(step.total) .. ")"

					log:debug(percentageString)
					log:debug(xofy)

					table.insert(secondLineTable, percentageString)
					table.insert(secondLineTable, xofy)
				end
				-- XXX: do something with time here

				-- put the secondLineTable together as one string
				local secondLine = table.concat(secondLineTable, ' ')
				-- add the second line to the report
				table.insert(progressReport, secondLine)
			end
		end
		if hasData then
			return table.concat(progressReport, "\n") 
		else
			-- no data
			return self:string('SCANNER_NO_STATUS')
		end
	else
		-- no data
		return self:string('SCANNER_NO_STATUS')
	end
end


function _secondsToString(seconds)
	local hrs = math.floor(seconds / 3600)
	local min = math.floor((seconds / 60) - (hrs*60))
	local sec = math.floor( seconds - (hrs*3600) - (min*60) )

	if hrs > 0 then
		return string.format("%d:%02d:%02d", hrs, min, sec)
	else
		return string.format("%d:%02d", min, sec)
	end
end

--[[

=head1 LICENSE

Copyright 2007 Logitech. All Rights Reserved.

This file is subject to the Logitech Public Source License Version 1.0. Please see the LICENCE file for details.

=cut
--]]
