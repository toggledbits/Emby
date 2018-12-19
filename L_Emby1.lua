--[[
    L_Emby.lua - Core module for Emby
    Copyright 2017,2018 Patrick H. Rigney, All Rights Reserved.
    This file is part of Emby. For license information, see LICENSE at https://github.com/toggledbits/Emby
--]]
--luacheck: std lua51,module,read globals luup,ignore 542 611 612 614 111/_,no max line length

module("L_Emby1", package.seeall)

local debugMode = false

local _PLUGIN_ID = 99999
local _PLUGIN_NAME = "Emby"
local _PLUGIN_VERSION = "0.1-181219"
local _PLUGIN_URL = "https://www.toggledbits.com/emby"
local _CONFIGVERSION = 000000

local MYSID = "urn:toggledbits-com:serviceId:Emby1"
local MYTYPE = "urn:schemas-toggledbits-com:device:Emby:1"

local tickTasks = {}
local maxEvents = 50

local runStamp = 0
local pluginDevice = 0
local isALTUI = false
local isOpenLuup = false

local json = require("dkjson")

local function dump(t, seen)
    if t == nil then return "nil" end
    if seen == nil then seen = {} end
    local sep = ""
    local str = "{ "
    for k,v in pairs(t) do
        local val
        if type(v) == "table" then
            if seen[v] then val = "(recursion)"
            else
                seen[v] = true
                val = dump(v, seen)
            end
        elseif type(v) == "string" then
            val = string.format("%q", v)
        elseif type(v) == "number" and (math.abs(v-os.time()) <= 86400) then
            val = tostring(v) .. "(" .. os.date("%x.%X", v) .. ")"
        else
            val = tostring(v)
        end
        str = str .. sep .. k .. "=" .. val
        sep = ", "
    end
    str = str .. " }"
    return str
end

local function L(msg, ...) -- luacheck: ignore 212
    local str
    local level = 50
    if type(msg) == "table" then
        str = tostring(msg.prefix or _PLUGIN_NAME) .. ": " .. tostring(msg.msg)
        level = msg.level or level
    else
        str = _PLUGIN_NAME .. ": " .. tostring(msg)
    end
    str = string.gsub(str, "%%(%d+)", function( n )
            n = tonumber(n, 10)
            if n < 1 or n > #arg then return "nil" end
            local val = arg[n]
            if type(val) == "table" then
                return dump(val)
            elseif type(val) == "string" then
                return string.format("%q", val)
            elseif type(val) == "number" and math.abs(val-os.time()) <= 86400 then
                return tostring(val) .. "(" .. os.date("%x.%X", val) .. ")"
            end
            return tostring(val)
        end
    )
    luup.log(str, level)
end

local function D(msg, ...)
    if debugMode then
        L( { msg=msg,prefix=(_PLUGIN_NAME .. "(debug)") }, ... )
    end
end

local function checkVersion(dev)
    local ui7Check = luup.variable_get(MYSID, "UI7Check", dev) or ""
    if isOpenLuup then 
        return true
    end
    if luup.version_branch == 1 and luup.version_major == 7 then
        if ui7Check == "" then
            -- One-time init for UI7 or better
            luup.variable_set( MYSID, "UI7Check", "true", dev )
        end
        return true
    end
    L({level=1,msg="firmware %1 (%2.%3.%4) not compatible"}, luup.version,
        luup.version_branch, luup.version_major, luup.version_minor)
    return false
end

local function urlencode( str )
    str = tostring(str):gsub( "([^A-Za-z0-9_ -])", function( ch ) return string.format("%%%02x", string.byte( ch ) ) end )
    return str:gsub( " ", "+" )
end

local function split( str, sep )
    if sep == nil then sep = "," end
    local arr = {}
    if #str == 0 then return arr, 0 end
    local rest = string.gsub( str or "", "([^" .. sep .. "]*)" .. sep, function( m ) table.insert( arr, m ) return "" end )
    table.insert( arr, rest )
    return arr, #arr
end

-- Shallow copy
local function shallowCopy( t )
    local r = {}
    for k,v in pairs(t) do
        r[k] = v
    end
    return r
end

-- Initialize a variable if it does not already exist.
local function initVar( name, dflt, dev, sid )
    assert( dev ~= nil )
    assert( sid ~= nil )
    local currVal = luup.variable_get( sid, name, dev )
    if currVal == nil then
        luup.variable_set( sid, name, tostring(dflt), dev )
        return tostring(dflt)
    end
    return currVal
end

-- Set variable, only if value has changed.
local function setVar( sid, name, val, dev )
    local s = luup.variable_get( sid, name, dev )
    if s ~= val then
        luup.variable_set( sid, name, val, dev )
        return val
    end
    return s
end

-- Get numeric variable, or return default value if not set or blank
local function getVarNumeric( name, dflt, dev, sid )
    assert( dev ~= nil )
    assert( name ~= nil )
    if sid == nil then sid = RSSID end
    local s = luup.variable_get( sid, name, dev )
    if (s == nil or s == "") then return dflt end
    s = tonumber(s, 10)
    if (s == nil) then return dflt end
    return s
end

-- Find device by name
local function findDeviceByName( n )
    n = tostring(n):lower()
    for k,v in pairs( luup.devices ) do
        if tostring(v.description):lower() == n then
            return k,v
        end
    end
    return nil
end

-- Add an event to the event list. Prune the list for size.
local function addEvent( t )
    local p = shallowCopy(t)
    if p.event == nil then L({level=1,msg="addEvent(%1) missing 'event'"},t) end
    if p.dev == nil then L({level=2,msg="addEvent(%1) missing 'dev'"},t) end
    p.when = os.time()
    p.time = os.date("%Y%m%dT%H%M%S")
    local dev = p.dev or pluginDevice
    sensorState[tostring(dev)] = sensorState[tostring(dev)] or { eventList={} }
    table.insert( sensorState[tostring(dev)].eventList, p )
    if #sensorState[tostring(dev)].eventList > maxEvents then table.remove(sensorState[tostring(dev)].eventList, 1) end
end

-- Enabled?
local function isEnabled( dev )
    return getVarNumeric( "Enabled", 1, dev, RSSID ) ~= 0
end

-- Schedule a timer tick for a future (absolute) time. If the time is sooner than
-- any currently scheduled time, the task tick is advanced; otherwise, it is
-- ignored (as the existing task will come sooner), unless repl=true, in which
-- case the existing task will be deferred until the provided time.
local function scheduleTick( tinfo, timeTick, flags )
    D("scheduleTick(%1,%2,%3)", tinfo, timeTick, flags)
    flags = flags or {}
    local function nulltick(d,p) L({level=1, "nulltick(%1,%2)"},d,p) end
    local tkey = tostring( type(tinfo) == "table" and tinfo.id or tinfo )
    assert(tkey ~= nil)
    if ( timeTick or 0 ) == 0 then
        D("scheduleTick() clearing task %1", tinfo)
        tickTasks[tkey] = nil
        return
    elseif tickTasks[tkey] then
        -- timer already set, update
        tickTasks[tkey].func = tinfo.func or tickTasks[tkey].func
        tickTasks[tkey].args = tinfo.args or tickTasks[tkey].args
        tickTasks[tkey].info = tinfo.info or tickTasks[tkey].info
        if tickTasks[tkey].when == nil or timeTick < tickTasks[tkey].when or flags.replace then
            -- Not scheduled, requested sooner than currently scheduled, or forced replacement
            tickTasks[tkey].when = timeTick
        end
        D("scheduleTick() updated %1", tickTasks[tkey])
    else
        assert(tinfo.owner ~= nil)
        assert(tinfo.func ~= nil)
        tickTasks[tkey] = { id=tostring(tinfo.id), owner=tinfo.owner, when=timeTick, func=tinfo.func or nulltick, args=tinfo.args or {},
            info=tinfo.info or "" } -- new task
        D("scheduleTick() new task %1 at %2", tinfo, timeTick)
    end
    -- If new tick is earlier than next plugin tick, reschedule
    tickTasks._plugin = tickTasks._plugin or {}
    if tickTasks._plugin.when == nil or timeTick < tickTasks._plugin.when then
        tickTasks._plugin.when = timeTick
        local delay = timeTick - os.time()
        if delay < 1 then delay = 1 end
        D("scheduleTick() rescheduling plugin tick for %1", delay)
        runStamp = runStamp + 1
        luup.call_delay( "embyTaskTick", delay, runStamp )
    end
    return tkey
end

-- Schedule a timer tick for after a delay (seconds). See scheduleTick above
-- for additional info.
local function scheduleDelay( tinfo, delay, flags )
    D("scheduleDelay(%1,%2,%3)", tinfo, delay, flags )
    if delay < 1 then delay = 1 end
    return scheduleTick( tinfo, delay+os.time(), flags )
end

--[[ 
    ***************************************************************************
    A C T I O N   I M P L E M E N T A T I O N
    ***************************************************************************
--]]

-- Enable or disable debug
function actionSetDebug( state, tdev )
    assert(tdev == pluginDevice) -- on master only
    if string.find( ":debug:true:t:yes:y:1:", string.lower(tostring(state)) ) then
        debugMode = true
    else
        local n = tonumber(state or "0") or 0
        debugMode = n ~= 0
    end
    addEvent{ event="actionSetDebug", dev=tdev, debugMode=debugMode }
    if debugMode then
        D("Debug enabled")
    end
end

--[[ 
    ***************************************************************************
    P L U G I N   B A S E
    ***************************************************************************
--]]
-- plugin_runOnce() looks to see if a core state variable exists; if not, a 
-- one-time initialization takes place.
local function plugin_runOnce( pdev )
    local s = getVarNumeric("Version", 0, pdev, MYSID)
    if s == _CONFIGVERSION then
        -- Up to date.
        return
    elseif s == 0 then
        L("First run, setting up new plugin instance...")
        initVar( "Message", "", pdev, MYSID )
        initVar( "DebugMode", 0, pdev, MYSID )

        luup.attr_set('category_num', 1, pdev)

        luup.variable_set( MYSID, "Version", _CONFIGVERSION, pdev )
        return
    end

    -- Consider per-version changes.

    -- Update version last.
    if s ~= _CONFIGVERSION then
        luup.variable_set( MYSID, "Version", _CONFIGVERSION, pdev )
    end
end

-- Tick handler for master device
local function masterTick(pdev,taskid)
    D("masterTick(%1,%2)", pdev,taskid)
    assert(pdev == pluginDevice)
    -- Set default time for next master tick
    local nextTick = math.floor( os.time() / 60 + 1 ) * 60
    
    -- Do master tick work here (dispatch)

    -- Schedule next master tick.
    scheduleTick( taskid, nextTick )
end

-- Start plugin running.
function startPlugin( pdev )
    L("plugin version %2, device %1 (%3)", pdev, _PLUGIN_VERSION, luup.devices[pdev].description)
    
    luup.variable_set( MYSID, "Message", "Initializing...", pdev )

    -- Early inits
    pluginDevice = pdev
    isALTUI = false
    isOpenLuup = false
    tickTasks = {}
    maxEvents = getVarNumeric( "MaxEvents", 50, pdev, MYSID )
    
    -- Debug?
    if getVarNumeric( "DebugMode", 0, pdev, MYSID ) ~= 0 then
        debugMode = true
        D("startPlugin() debug enabled by state variable DebugMode")
    end

    -- Check for ALTUI and OpenLuup
    local failmsg = false
    for k,v in pairs(luup.devices) do
        if v.device_type == "urn:schemas-upnp-org:device:altui:1" then
            D("start() detected ALTUI at %1", k)
            isALTUI = true
            --[[
            local rc,rs,jj,ra = luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin",
                {
                    newDeviceType=MYTYPE,
                    newScriptFile="",
                    newDeviceDrawFunc="",
                    newStyleFunc=""
                }, k )
            D("startSensor() ALTUI's RegisterPlugin action for %5 returned resultCode=%1, resultString=%2, job=%3, returnArguments=%4", rc,rs,jj,ra, MYTYPE)
            --]]
        elseif v.device_type == "openLuup" then
            D("start() detected openLuup")
            isOpenLuup = true
        end
    end
    if failmsg then
        return false, failmsg, _PLUGIN_NAME
    end

    -- Check UI version
    if not checkVersion( pdev ) then
        L({level=1,msg="This plugin does not run on this firmware."})
        luup.variable_set( MYSID, "Message", "Unsupported firmware "..tostring(luup.version), pdev )
        luup.set_failure( 1, pdev )
        return false, "Incompatible firmware " .. luup.version, _PLUGIN_NAME
    end

    -- One-time stuff
    plugin_runOnce( pdev )

    -- More inits
    
    -- Initialize and start the plugin timer and master tick
    runStamp = 1
    scheduleDelay( { id="master", func=masterTick, owner=pdev }, 5 )

    -- Return success
    luup.set_failure( 0, pdev )
    return true, "Ready", _PLUGIN_NAME
end

-- Plugin timer tick. Using the tickTasks table, we keep track of tasks that 
-- need to be run and when, and try to stay on schedule. This keeps us light on 
-- resources: typically one system timer only for any number of devices.
local functions = { [tostring(masterTick)]="masterTick" }
function taskTickCallback(p)
    D("taskTickCallback(%1) pluginDevice=%2", p, pluginDevice)
    local stepStamp = tonumber(p,10)
    assert(stepStamp ~= nil)
    if stepStamp ~= runStamp then
        D( "taskTickCallback() stamp mismatch (got %1, expecting %2), newer thread running. Bye!",
            stepStamp, runStamp )
        return
    end

    local now = os.time()
    local nextTick = now + 60 -- Try to start minute to minute at least
    tickTasks._plugin.when = 0

    -- Since the tasks can manipulate the tickTasks table, the iterator
    -- is likely to be disrupted, so make a separate list of tasks that
    -- need service, and service them using that list.
    local todo = {}
    for t,v in pairs(tickTasks) do
        if t ~= "_plugin" and v.when ~= nil and v.when <= now then
            -- Task is due or past due
            D("taskTickCallback() inserting eligible task %1 when %2 now %3", v.id, v.when, now)
            v.when = nil -- clear time; timer function will need to reschedule
            table.insert( todo, v )
        end
    end

    -- Run the to-do list.
    D("taskTickCallback() to-do list is %1", todo)
    for _,v in ipairs(todo) do
        D("taskTickCallback() calling task function %3(%4,%5) for %1 (%2)", v.owner, (luup.devices[v.owner] or {}).description, functions[tostring(v.func)] or tostring(v.func),
            v.owner,v.id)
        local success, err = pcall( v.func, v.owner, v.id, v.args )
        if not success then
            L({level=1,msg="Emby device %1 (%2) tick failed: %3"}, v.owner, (luup.devices[v.owner] or {}).description, err)
            addEvent{ dev=v.owner, event="error", message="tick failed", reason=err }
        else
            D("taskTickCallback() successful return from %2(%1)", v.owner, functions[tostring(v.func)] or tostring(v.func))
        end
    end

    -- Things change while we work. Take another pass to find next task.
    for t,v in pairs(tickTasks) do
        if t ~= "_plugin" and v.when ~= nil then
            if nextTick == nil or v.when < nextTick then
                nextTick = v.when
            end
        end
    end

    -- Figure out next master tick, or don't resched if no tasks waiting.
    if nextTick ~= nil then
        D("taskTickCallback() next eligible task scheduled for %1", os.date("%x %X", nextTick))
        now = os.time() -- Get the actual time now; above tasks can take a while.
        local delay = nextTick - now
        if delay < 1 then delay = 1 end
        tickTasks._plugin.when = now + delay
        D("taskTickCallback() scheduling next tick(%3) for %1 (%2)", delay, tickTasks._plugin.when,p)
        luup.call_delay( "embyTaskTick", delay, p )
    else
        D("taskTickCallback() not rescheduling, nextTick=%1, stepStamp=%2, runStamp=%3", nextTick, stepStamp, runStamp)
        tickTasks._plugin.when = nil
    end
end

-- Watch callback. Dispatches to child-specific handling.
function watchCallback( dev, sid, var, oldVal, newVal )
    D("watchCallback(%1,%2,%3,%4,%5)", dev, sid, var, oldVal, newVal)
    assert(var ~= nil) -- nil if service or device watch (can happen on openLuup)
end

local EOL = "\r\n"

local function getDevice( dev, pdev, v )
    if v == nil then v = luup.devices[dev] end
    if json == nil then json = require("dkjson") end
    local devinfo = {
          devNum=dev
        , ['type']=v.device_type
        , description=v.description or ""
        , room=v.room_num or 0
        , udn=v.udn or ""
        , id=v.id
        , parent=v.device_num_parent or pdev
        , ['device_json'] = luup.attr_get( "device_json", dev )
        , ['impl_file'] = luup.attr_get( "impl_file", dev )
        , ['device_file'] = luup.attr_get( "device_file", dev )
        , manufacturer = luup.attr_get( "manufacturer", dev ) or ""
        , model = luup.attr_get( "model", dev ) or ""
    }
    local rc,t,httpStatus,uri
    if isOpenLuup then
        uri = "http://localhost:3480/data_request?id=status&DeviceNum=" .. dev .. "&output_format=json"
    else
        uri = "http://localhost/port_3480/data_request?id=status&DeviceNum=" .. dev .. "&output_format=json"
    end
    rc,t,httpStatus = luup.inet.wget(uri, 15)
    if httpStatus ~= 200 or rc ~= 0 then
        devinfo['_comment'] = string.format( 'State info could not be retrieved, rc=%s, http=%s', tostring(rc), tostring(httpStatus) )
        return devinfo
    end
    local d = json.decode(t)
    local key = "Device_Num_" .. dev
    if d ~= nil and d[key] ~= nil and d[key].states ~= nil then d = d[key].states else d = nil end
    devinfo.states = d or {}
    return devinfo
end

local function getEvents( deviceNum )
    if deviceNum == nil or luup.devices[deviceNum] == nil or luup.devices[deviceNum].device_type ~= RSTYPE then
        return "no events: device does not exist or is not EmbySensor"
    end
    local resp = "    Events" .. EOL
    for _,e in ipairs( ( sensorState[tostring(deviceNum)] or {}).eventList or {} ) do
        resp = resp .. string.format("        %15s ", os.date("%x %X", e.when or 0) )
        resp = resp .. ( e.event or "event?" ) .. ":"
        for k,v in pairs(e) do
            if not ( k == "time" or k == "when" or k == "event" or ( k == "dev" and tostring(v)==tostring(deviceNum) ) ) then
                resp = resp .. string.format(" %s=%s,", tostring(k), tostring(v))
            end
        end
        resp = resp .. EOL
    end
    return resp
end

local function alt_json_encode( st )
    str = "{"
    local comma = false
    for k,v in pairs(st) do
        str = str .. ( comma and "," or "" )
        comma = true
        str = str .. '"' .. k .. '":'
        if type(v) == "table" then
            str = str .. alt_json_encode( v )
        elseif type(v) == "number" then
            str = str .. tostring(v)
        elseif type(v) == "boolean" then
            str = str .. ( v and "true" or "false" )
        else
            str = str .. string.format("%q", tostring(v))
        end
    end
    str = str .. "}"
    return str
end

function handleLuupRequest( lul_request, lul_parameters, lul_outputformat )
    D("request(%1,%2,%3) luup.device=%4", lul_request, lul_parameters, lul_outputformat, luup.device)
    local action = lul_parameters['action'] or lul_parameters['command'] or ""
    local deviceNum = tonumber( lul_parameters['device'], 10 )
    if action == "debug" then
        debugMode = not debugMode
        D("debug set %1 by request", debugMode)
        return "Debug is now " .. ( debugMode and "on" or "off" ), "text/plain"

    elseif action == "status" then
        local st = {
            name=_PLUGIN_NAME,
            plugin=_PLUGIN_ID,
            version=_PLUGIN_VERSION,
            configversion=_CONFIGVERSION,
            author="Patrick H. Rigney (rigpapa)",
            url=_PLUGIN_URL,
            ['type']=MYTYPE,
            responder=luup.device,
            timestamp=os.time(),
            system = {
                version=luup.version,
                isOpenLuup=isOpenLuup,
                isALTUI=isALTUI
            },
            devices={}
        }
        for k,v in pairs( luup.devices ) do
            if v.device_type == MYTYPE or v.parent_device_num == pluginDevice then
                local devinfo = getDevice( k, pluginDevice, v ) or {}
                if k == pluginDevice then
                    devinfo.tickTasks = tickTasks
                end
                table.insert( st.devices, devinfo )
            end
        end
        return alt_json_encode( st ), "application/json"
        
    else
        error("Not implemented: " .. action)
    end
end

-- Return the plugin version string
function getPluginVersion()
    return _PLUGIN_VERSION, _CONFIGVERSION
end