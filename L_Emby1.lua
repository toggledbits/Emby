--[[
    L_Emby1.lua - Core module for Emby
    Copyright 2017,2018,2019 Patrick H. Rigney, All Rights Reserved.
    This file is part of Emby. For license information, see LICENSE at https://github.com/toggledbits/Emby
--]]
--luacheck: std lua51,module,read globals luup,ignore 542 611 612 614 111/_,no max line length

module("L_Emby1", package.seeall)

local debugMode = false

firstbyte = true -- ??? temporary

local _PLUGIN_ID = 9181
local _PLUGIN_NAME = "Emby"
local _PLUGIN_VERSION = "1.1develop"
local _PLUGIN_URL = "https://www.toggledbits.com/emby"
local _CONFIGVERSION = 000101

local math = require "math"
local string = require "string"
local socket = require "socket"
local http = require "socket.http"
local ltn12 = require "ltn12"
local json = require "dkjson"
local bit = require "bit"

local MYSID = "urn:toggledbits-com:serviceId:Emby1"
local MYTYPE = "urn:schemas-toggledbits-com:device:Emby:1"

local SERVERSID = "urn:toggledbits-com:serviceId:EmbyServer1"
local SERVERTYPE = "urn:schemas-toggledbits-com:device:EmbyServer:1"
local SESSIONSID = "urn:toggledbits-com:serviceId:EmbySession1"
local SESSIONTYPE = "urn:schemas-toggledbits-com:device:EmbySession:1"

local tickTasks = {}
local maxEvents = 50
local devData = {}

local runStamp = 0
local pluginDevice = 0
local isALTUI = false
local isOpenLuup = false
local deferClear = false

local DISCOVERYPERIOD = 15

local STATE_START = "start"
local STATE_READLEN1 = "len"
local STATE_READLEN161 = "len16-1"
local STATE_READLEN162 = "len16-2"
local STATE_READDATA = "data"
local STATE_SYNC = "sync"
local STATE_SYNC = "resync"
local STATE_ERROR = "error"

local handleIncomingMessage

function dump(t, seen)
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
            if #v > 255 then val = string.format("%q", v:sub(1,252).."...")
            else val = string.format("%q", v) end
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

local function wsopen( url, server )
    D("wsopen(%1,%2)", url, server)

    url = url:gsub("^http", "ws")
    local port
    local proto, ip, ps = url:match("^(wss?)://([^:/]+)(.*)")
    if not proto then
        error("Invalid protocol/address for WebSocket open in " .. url)
    elseif ps then
        port = ps:match(":(%d+)")
    else
        port = 8096
    end

    -- Save IP and port
    -- ??? don't do this, so Luup doesn't auto-open socket (and fuck it up later)
    -- luup.attr_set( 'ip', string.format( "%s:%n", ip, port ), server )

    local ds = devData[tostring(server)]
    ds.wsconnected = false
    ds.ip = ip
    ds.port = port
    ds.readstate = STATE_START

    -- This call is async -- it returns immediately.
    luup.io.open( server, ip, port )
end

-- WebSocket connect--connect on open socket
local function wsconnect( server )
    D("wsconnect(%1)", server)

    local ds = devData[tostring(server)]

    -- Handshake
    local apikey = luup.variable_get( SERVERSID, "APIKey", server ) or ""
    local req = string.format("GET /embywebsocket?api_key=%s&deviceId=ef22e84e4caad209b23899602c3e6019 HTTP/1.1\nHost: %s\nUpgrade: websocket\nConnection: Upgrade\nSec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==\nSec-WebSocket-Protocol: chat, superchat\nSec-WebSocket-Version: 13\n\n",
        apikey, ds.ip)

    -- Signal Luup that we want to read data ourselves here (precedes write).
    luup.io.intercept( server )

    -- Send request.
    D("wsconnect() sending %1", req)
    if not luup.io.write( req, server ) then
        D("wsconnect() write of request failed")
        return false
    end
    local resp = ""
    local lastch = ""
    -- Read until we get two consecutive linefeeds.
    while true do
        local b = luup.io.read( 5, server )
        D("wsconnect() received %1 (%2)", b, string.byte(b))
        if (b or "") == "" then break end
        resp = resp .. b
        b = string.byte(b)
        if b == 10 and lastch == 10 then break end
        if b ~= 13 then lastch = b end
        if #resp == 13 and resp:match( "^HTTP/1%.. 101 " ) then
            D("wsconnect() SUCCESSFUL NEGOTATION COMING!")
        end
    end
    D("wsconnect() full response is %1", resp)
    if resp:match( "^HTTP/1%.. 101 " ) then
        D("wsconnect() negotiation succeeded!")
        if debugMode then luup.log(resp,2) end
        ds.wsconnected = true
        ds.readstate = STATE_START
        return true -- Flag now in websocket protocol
    else
        D("wsconnect() negotiation failed, luup.io.read returned %1", resp)
    end
    L({level=1,msg="%1 (%2) unable to open WebSocket"}, luup.devices[server].description, server)
    return false
end

local function wssend( opcode, s, server )
    D("wssend(%1,%2,%3)", opcode, s, server)
    if type(s) == "table" then s = json.encode( s ) else s = tostring( s ) or "" end
    local b = bit.bor( 0x80, opcode ) -- fin
    local frame = string.char(b)
    if #s < 126 then
        frame = frame .. string.char(#s)
    elseif #s <= 65535 then
        frame = frame .. string.char(126) -- indicate 16-bit length follows
        frame = frame .. string.char( math.floor( #s / 256 ) )
        frame = frame .. string.char( #s % 256 )
    else
        error("Super-long frame length not implemented")
    end
    frame = frame .. s
    D("wssend() server %1 sending frame of %2 bytes for %3", server, #frame, s)
    return luup.io.write( frame, server )
end

local function handleIncomingByte( b, server )
    -- D("handleIncomingByte(%1,%2)", b, server)
    local sd = devData[tostring(server)]
    if sd.readstate == STATE_START then
        sd.fin = bit.band( b, 128 ) > 0
        sd.opcode = bit.band( b, 15 )
        sd.mlen = 0
        sd.size = 0
        sd.mask = 0
        sd.msg = ""
        sd.readstate = STATE_READLEN1
        sd.start = socket.gettime()
        if not sd.fin then sd.readstate = STATE_SYNC end
    elseif sd.readstate == STATE_READLEN1 then
        sd.mask = bit.band( b, 128 )
        sd.mlen = bit.band( b, 127 )
        if sd.mlen == 126 then
            -- Payload length in 16 bit integer that follows, read 2 bytes (big endian)
            sd.readstate = STATE_READLEN161
        elseif sd.mlen == 127 then
            -- 64-bit length (unsupported, ignore message)
            sd.readstate = STATE_SYNC
        else
            if sd.mlen > 0 then
                sd.size = sd.mlen
                sd.readstate = STATE_READDATA
            else
                -- No data with this opcode
                sd.size = 0
                handleIncomingMessage( sd.opcode, "", server )
                sd.readstate = STATE_START
            end
        end
        D("handleIncomingByte() opcode %1 len %2 next state %3", sd.opcode, sd.mlen, sd.readstate)
    elseif sd.readstate == STATE_READLEN161 then
        sd.mlen = b * 256
        sd.readstate = STATE_READLEN162
    elseif sd.readstate == STATE_READLEN162 then
        sd.mlen = sd.mlen + b
        sd.size = sd.mlen
        sd.readstate = STATE_READDATA
        D("handleIncomingByte() finished 16-bit length read, new len is %1", sd.mlen)
    elseif sd.readstate == STATE_READDATA then
        sd.msg = sd.msg .. string.char( b )
        sd.mlen = sd.mlen - 1
        if debugMode and sd.mlen % 2500 == 0 then D("handleIncomingByte() reading message, %1 bytes to go", sd.mlen) end
        if sd.mlen <= 0 then
            local delta = math.max( socket.gettime() - sd.start, 0.001 )
            D("handleIncomingByte() message received, %1 bytes in %2 secs, %3 bytes/sec", sd.size, delta, sd.size / delta)
            handleIncomingMessage( sd.opcode, sd.msg, server )
            sd.readstate = STATE_START
        end
    elseif sd.readstate == STATE_SYNC then
        -- Need to resync. Look for a ping (opcode 9, fin set, length 0)
        if b == 0x89 then
            sd.readstate = STATE_RESYNC
        end
    elseif sd.readstate == STATE_RESYNC then
        -- Here's where we look for the zero length following the ping op
        if b == 0x89 then
            -- no state change
        elseif b == 0 then
            -- Good ping (likely)
            D("handleIncomingByte() **** RESYNC ****")
            sd.readstate = STATE_START
        else
            -- Nope, start over.
            sd.readstate = STATE_SYNC
        end
    elseif sd.readstate == STATE_ERROR then
        -- Just consume (ignore) data until we time out
        error("FIX ME") -- ??? stuck in jail, how to get out of this state?
    else
        assert(false, "Invalid state in handleIncomingByte: "..tostring(sd.readstate))
    end
    -- D("handleIncomingByte() next state is %1, sd now %2", sd.readstate, sd)
end

function handleIncoming( data, server )
    -- D("handleIncoming(%1 bytes,%2)", #data, server)
    if #data == 1 then
        handleIncomingByte( data:byte(), server ) -- fast!
    else
        for ix=1,#data do
            local byte = string.byte(data,ix)
            handleIncomingByte( byte, server )
        end
    end
end

--[[
local function wsdecode( data, server )
    -- Read first byte (header)
    local b, err = sock:receive( 1 )
    if b == nil or err then
        D("wsreceive() lead-in scan, got %1(%2) err %3", b, b and string.byte(b) or 0, err)
        return false
    end
    b = string.byte( b )
    local fin = bit.band( b, 128 ) > 0
    local opcode = bit.band( b, 15 )
    sock:settimeout( 1 )
    b, err = sock:receive( 1 )
    if b == nil or err then
        D("wsreceive() missing length byte")
        return false
    end
    -- Read first payload byte (minimum read is 2 bytes, header and payload).
    b = string.byte( b )
    local mask = bit.band( b, 128 )
    local mlen = bit.band( b, 127 )
    if mlen == 126 then
        -- Payload length in 16 bit integer that follows, read 2 bytes (big endian)
        b, err = sock:receive( 2 )
        if b == nil or err then
            D("wsreceive() missing extended length byte")
            return false
        end
        mlen = string.byte( b, 1 ) * 256 + string.byte( b, 2 )
    elseif mlen == 127 then
        -- 64 bit length (2x32)
        error("no implementation")
    end
    D("wsreceive() header received, opcode=%1, mask=%2, datalen=%3", opcode, mask, mlen)
    local msg = ""
    while mlen > 0 do
        local nn = (mlen < 64) and mlen or 64
        b, err = sock:receive( nn )
        if b == nil or err then
            D("wsreceive() early end of data with %1 bytes remaining", mlen)
            return false
        end
        msg = msg .. b
        mlen = mlen - nn
    end
    D("wsreceive() received data complete")
    return opcode, msg
end
--]]

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

-- Array to map, where f(elem) returns key[,value]
local function map( arr, f, res )
    res = res or {}
    for _,x in ipairs( arr ) do
        if f then
            local k,v = f( x )
            res[k] = (v == nil) and x or v
        else
            res[x] = x
        end
    end
    return res
end

-- Initialize a variable if it does not already exist.
local function initVar( name, dflt, dev, sid )
    assert( dev ~= nil, "initVar requires dev" )
    assert( sid ~= nil, "initVar requires SID for "..name )
    local currVal = luup.variable_get( sid, name, dev )
    if currVal == nil then
        luup.variable_set( sid, name, tostring(dflt), dev )
        return tostring(dflt)
    end
    return currVal
end

-- Set variable, only if value has changed.
local function setVar( sid, name, val, dev )
    val = (val == nil) and "" or tostring(val)
    local s = luup.variable_get( sid, name, dev ) or ""
    -- D("setVar(%1,%2,%3,%4) old value %5", sid, name, val, dev, s )
    if s ~= val then
        luup.variable_set( sid, name, val, dev )
    end
    return s
end

-- Get numeric variable, or return default value if not set or blank
local function getVarNumeric( name, dflt, dev, sid )
    assert( dev ~= nil )
    assert( name ~= nil )
    assert( sid ~= nil )
    local s = luup.variable_get( sid, name, dev ) or ""
    if s == "" then return dflt end
    s = tonumber(s)
    return (s == nil) and dflt or s
end

-- Add an event to the event list. Prune the list for size.
local function addEvent( t )
    local p = shallowCopy(t)
    if p.event == nil then L({level=1,msg="addEvent(%1) missing 'event'"},t) end
    if p.dev == nil then L({level=2,msg="addEvent(%1) missing 'dev'"},t) end
    p.when = os.time()
    p.time = os.date("%Y%m%dT%H%M%S")
    local dev = p.dev or pluginDevice
    if devData[tostring(dev)] == nil then devData[tostring(dev)] = {} end
    devData[tostring(dev)].eventList = devData[tostring(dev)].eventList or {}
    table.insert( devData[tostring(dev)].eventList, p )
    if #devData[tostring(dev)].eventList > maxEvents then table.remove(devData[tostring(dev)].eventList, 1) end
end

-- Enabled?
local function isEnabled( dev )
    return getVarNumeric( "Enabled", 1, dev, MYSID ) ~= 0
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

local function gatewayStatus( m )
    setVar( MYSID, "Message", m or "", pluginDevice )
end

local function getChildDevices( typ, parent, filter )
    parent = parent or pluginDevice
    local res = {}
    for k,v in pairs(luup.devices) do
        if v.device_num_parent == parent and ( typ == nil or v.device_type == typ ) and ( filter==nil or filter(k, v) ) then
            table.insert( res, k )
        end
    end
    return res
end

--[[ Prep for adding new children via the luup.chdev mechanism. The existingChildren
     table (array) should contain device IDs of existing children that will be
     preserved. Any existing child not listed will be dropped. If the table is nil,
     all existing children in luup.devices will be preserved.
--]]
local function prepForNewChildren( existingChildren )
    D("prepForNewChildren(%1)", existingChildren)
    local dfMap = { [SERVERTYPE]="D_EmbyServer1.xml", [SESSIONTYPE]="D_EmbySession1.xml" }
    if existingChildren == nil then
        existingChildren = {}
        for k,v in pairs( luup.devices ) do
            if v.device_num_parent == pluginDevice then
                assert(dfMap[v.device_type]~=nil, "BUG: device type missing from dfMap: "..v.device_type)
                table.insert( existingChildren, k )
            end
        end
    end
    local ptr = luup.chdev.start( pluginDevice )
    for _,k in ipairs( existingChildren ) do
        local v = luup.devices[k]
        assert(v)
        assert(v.device_num_parent == pluginDevice)
        D("prepForNewChildren() appending existing child %1 (%2/%3)", v.description, k, v.id)
        luup.chdev.append( pluginDevice, ptr, v.id, v.description, "",
            dfMap[v.device_type] or error("Invalid device type in child "..k),
            "", "", false )
    end
    return ptr, existingChildren
end

local function doRequest(method, url, tHeaders, body, dev)
    D("doRequest(%1,%2,%3,%4,%5)", method, url, tHeaders, body, dev)
    assert(dev ~= nil)
    method = method or "GET"

    local headers = tHeaders and shallowCopy(tHeaders) or {}
    if headers['X-Application'] == nil then headers['X-Application'] = "ToggledBits-Vera-Emby/" .. _PLUGIN_VERSION end
    if headers['Accepts'] == nil then headers['Accepts'] = "application/json" end

    -- A few other knobs we can turn
    local timeout = getVarNumeric("Timeout", 30, dev, MYSID) -- ???
    -- local maxlength = getVarNumeric("MaxLength", 262144, dev, DEVICESID) -- ???

    -- Build post/put data
    local src
    if type(body) == "table" then
        body = json.encode(body)
        headers["Content-Type"] = "application/json"
        D("doRequest() converted table to JSON body %1", body)
    else
        -- Caller should set Content-Type
    end
    headers["Content-Length"] = string.len(body or "")
    if body ~= nil then
        src = ltn12.source.string(body)
    end

    --[[
    -- Basic Auth
    local baUser = luup.variable_get( DEVICESID, "HTTPUser", dev ) or ""
    if baUser ~= "" then
        local baPass = luup.variable_get( DEVICESID, "HTTPPassword", dev ) or ""
        baUser = baUser .. ":" .. baPass
        local mime = require("mime")
        headers.Authorization = "Basic " + mime.b64( baUser )
    end
    --]]

    -- Make the request.
    local respBody, httpStatus
    local r = {}
    http.TIMEOUT = timeout -- N.B. http not https, regardless
    D("doRequest() requesting %2 %1, headers=%3", url, method, headers)
    respBody, httpStatus = http.request{
        url = url,
        source = src,
        sink = ltn12.sink.table(r),
        method = method,
        headers = headers,
        redirect = false
    }
    D("doRequest() request returned httpStatus=%1, respBody=%2", httpStatus, respBody)

    -- Since we're using the table sink, concatenate chunks to single string.
    respBody = table.concat(r)

    D("doRequest() response HTTP status %1, body=" .. respBody, httpStatus) -- use concat to avoid quoting

    -- Handle special errors from socket library
    if tonumber(httpStatus) == nil then
        respBody = httpStatus
        httpStatus = 500
    end

    -- See what happened. Anything 2xx we reduce to 200 (OK).
    if httpStatus >= 200 and httpStatus <= 299 then
        -- Success response with no data, take shortcut.
        return true, respBody, 200
    end
    if httpStatus == 401 then L{level=1,msg="API responded with authentication failure; check access token."} end
    return false, respBody, httpStatus
end

-- API request to server via local address
local function serverRequest( method, path, params, headers, body, dev )
    D("serverRequest(%1,%2,%3,%4,%5,%6)", method, path, params, headers, body, dev)
    assert(dev~=nil and luup.devices[dev].device_type==SERVERTYPE)
    local ea = {}
    for k,v in pairs(params or {}) do
        table.insert( ea, k .. "=" .. urlencode(tostring(v)) )
    end
    if not (params and params.api_key) then
        local key = luup.variable_get( SERVERSID, "APIKey", dev ) or ""
        if key:find("^[xX]*$") then return false, nil, 401 end
        table.insert( ea, "api_key=" .. urlencode(key) )
    end
    local fullurl = luup.variable_get( SERVERSID, "LocalAddress", dev ) or "http://localhost:8096"
    fullurl = fullurl .. "/emby" .. path .. "?" .. table.concat( ea, "&" )
    local success, resp, httpstat = doRequest( method or "GET", fullurl, headers, body, dev )
    D("serverRequest() doRequest returned %1,%2,%3", success, resp, httpstat)
    if success then
        if (resp or "") == "" then
            -- Empty response, which is OK
            return success, nil, 200
        end
if debugMode then
-- luup.log("Decoding json " .. tostring(#resp) .. " bytes:",2)
luup.log(resp,2)
local f = io.open( "/etc/cmh-ludl/emby-lastreply.json", "w" )
if f then f:write(resp) f:close() end
end
        local data,pos,err = json.decode( resp )
        if err then
            D("serverRequest() response data could not be decoded at %1, %2 in %3", pos, err, resp)
            return false, nil, 500
        end
        return true, data, httpstat
    end
    return success, resp, httpstat
end

local function isSessionCommandSupported( cmd, sessdev )
    D("isSessionCommandSupported(%1,%2)", cmd, sessdev)
    assert(luup.devices[sessdev] and luup.devices[sessdev].device_type == SESSIONTYPE)
    local s = luup.variable_get( SESSIONSID, "SupportedCommands", sessdev ) or ""
    if s == "" then return true end
    return string.find( ","..s..",", ","..cmd.."," ) ~= nil
end

-- Initialize session
local function initSession( sess )
    initVar( "Server", "0", sess, SESSIONSID )
    initVar( "Offline", "1", sess, SESSIONSID )
    initVar( "Visibility", "auto", sess, SESSIONSID )
    initVar( "DeviceId", "", sess, SESSIONSID )
    initVar( "DeviceName", "", sess, SESSIONSID )
    initVar( "Client", "", sess, SESSIONSID )
    initVar( "Version", "", sess, SESSIONSID )
    initVar( "VolumePercent", "100", sess, SESSIONSID )
    initVar( "DisplayPosition", "", sess, SESSIONSID )
    initVar( "Mute", "0", sess, "urn:micasaverde-com:serviceId:Volume1" )
    initVar( "SmartVolume", "0", sess, SESSIONSID )
    initVar( "SmartMute", "0", sess, SESSIONSID )
    initVar( "PlayingItemId", "", sess, SESSIONSID )
    initVar( "PlayingItemType", "", sess, SESSIONSID )
    initVar( "DisplayStatus", "", sess, SESSIONSID )
    initVar( "TransportState", "STOPPED", sess, SESSIONSID )
    initVar( "SmartSkipDefault", "", sess, SESSIONSID )
    initVar( "SmartSkipGrace", "", sess, SESSIONSID )

    if getVarNumeric( "Version", 0, sess, SESSIONSID ) < 000101 then
        luup.attr_set( 'category_num', 15, sess )
    end
    setVar( SESSIONSID, "Version", _CONFIGVERSION, sess )
end

local function clearPlayingState( child )
    setVar( SESSIONSID, "PlayingItemId", "", child )
    setVar( SESSIONSID, "PlayingItemType", "", child )
    setVar( SESSIONSID, "PlayingItemMediaType", "", child )
    setVar( SESSIONSID, "PlayingItemTitle", "", child )
    setVar( SESSIONSID, "PlayingItemArtist", "", child )
    setVar( SESSIONSID, "PlayingItemAlbum", "", child )
    setVar( SESSIONSID, "PlayingItemAlbumId", "", child )
    setVar( SESSIONSID, "PlayingItemPosition", "0", child )
    setVar( SESSIONSID, "PlayingItemRuntime", "0", child )
    setVar( SESSIONSID, "PlayingItemChapters", "", child )
    setVar( SESSIONSID, "DisplayPosition", "--:-- / --:--", child )
    setVar( SESSIONSID, "DisplayStatus", "", child )
    setVar( SESSIONSID, "TransportState", "STOPPED", child )
end

local function clearServerSessions( server )
    local children = getChildDevices( SESSIONTYPE, nil, function( child ) return getVarNumeric( "Server", 0, child, SESSIONSID ) == server end )
    for _,k in ipairs( children ) do
        clearPlayingState( k )
    end
end

local function clearChildren( pdev )
    local children = getChildDevices( SERVERTYPE, pdev )
    for _,k in ipairs( children ) do
        clearServerSessions( k )
        setVar( SERVERSID, "Message", "Stopped", k )
    end
end

local function updateSession( sdata, session, server )
    D("updateSession(%1,%2,%3)", "sdata", session, server)
    setVar( SESSIONSID, "Offline", 0, session )
    setVar( SESSIONSID, "Server", server, session )
    setVar( SESSIONSID, "DeviceName", sdata.DeviceName, session )
    setVar( SESSIONSID, "DeviceId", sdata.DeviceId, session )
    setVar( SESSIONSID, "Version", sdata.ApplicationVersion, session )
    setVar( SESSIONSID, "Client", sdata.Client, session )
    setVar( SESSIONSID, "LastActivity", sdata.LastActivityDate, session )

    D("updateSession() %1 name %2 (%3) PlayState %4", session, sdata.DeviceName, sdata.Client, sdata.PlayState)
    if sdata.PlayState then
        setVar( SESSIONSID, "VolumePercent", sdata.PlayState.VolumeLevel or "", session )
        setVar( "urn:micasaverde-com:serviceId:Volume1", "Mute", sdata.PlayState.IsMuted and 1 or 0, session )
    else
        setVar( SESSIONSID, "VolumePercent", "", session )
        setVar( "urn:micasaverde-com:serviceId:Volume1", "Mute", 0, session )
    end

    if sdata.SupportedCommands then
        setVar( SESSIONSID, "SupportedCommands", table.concat( sdata.SupportedCommands, "," ), session )
    else
        setVar( SESSIONSID, "SupportedCommands", "", session )
    end
    if sdata.PlayableMediaTypes then
        setVar( SESSIONSID, "PlayableMediaTypes", table.concat( sdata.PlayableMediaTypes, "," ), session )
    else
        setVar( SESSIONSID, "PlayableMediaTypes", "", session )
    end

    if sdata.NowPlayingItem then
        D("updateSession() %1 playing %2", sdata.DeviceName, sdata.NowPlayingItem)
        setVar( SESSIONSID, "PlayingItemId", sdata.NowPlayingItem.Id, session )
        setVar( SESSIONSID, "PlayingItemType", sdata.NowPlayingItem.Type, session )
        setVar( SESSIONSID, "PlayingItemMediaType", sdata.NowPlayingItem.MediaType, session )
        setVar( SESSIONSID, "PlayingItemTitle", sdata.NowPlayingItem.Name, session )
        setVar( SESSIONSID, "PlayingItemArtist", sdata.NowPlayingItem.AlbumArtist, session )
        setVar( SESSIONSID, "PlayingItemAlbumId", sdata.NowPlayingItem.AlbumId, session )
        setVar( SESSIONSID, "PlayingItemAlbum", sdata.NowPlayingItem.Album, session )

        local status = sdata.NowPlayingItem.Name
        if sdata.NowPlayingItem.MediaType == "Audio" then
            status = status .. " (" .. (sdata.NowPlayingItem.Album or "?")
            if ( sdata.NowPlayingItem.AlbumArtist or "" ) ~= "" then
                status = status .. " - " .. sdata.NowPlayingItem.AlbumArtist
            end
            status = status .. ")"
        end
        setVar( SESSIONSID, "DisplayStatus", status, session )

        local runtime = math.floor( (sdata.NowPlayingItem.RunTimeTicks or 0) / 10000 ) / 1000 -- frac seconds
        setVar( SESSIONSID, "PlayingItemRuntime", runtime, session )

        -- For video media, store any chapter data for "SmartSkip"
        if (sdata.NowPlayingItem.MediaType or ""):lower() == "video" and #(sdata.NowPlayingItem.Chapters or {}) > 0 then
            setVar( SESSIONSID, "PlayingItemChapters", json.encode( sdata.NowPlayingItem.Chapters ), session )
        else
            setVar( SESSIONSID, "PlayingItemChapters", "", session )
        end

        if sdata.PlayState then
            local ts = sdata.PlayState.IsPaused and "PAUSED" or "PLAYING"
            setVar( SESSIONSID, "TransportState", ts, session )
            local pos = math.floor( (sdata.PlayState.PositionTicks or 0) / 10000 ) / 1000
            setVar( SESSIONSID, "PlayingItemPosition", pos, session )
            local dp = string.format( "%02d:%02d / %02d:%02d", math.floor( pos / 60 ), math.floor( pos ) % 60,
                math.floor( runtime / 60 ), math.floor( runtime ) % 60 )
            setVar( SESSIONSID, "DisplayPosition", dp, session )
            setVar( SESSIONSID, "ResumePoint", sdata.NowPlayingItem.Id .. "," .. (sdata.PlayState.PositionTicks or 0), session )
            setVar( SESSIONSID, "ResumeTitle", sdata.NowPlayingItem.Name or "", session )
        end
    else
        D("updateSession() %1 not playing", sdata.DeviceName)
        clearPlayingState( session )
    end
end

local function isControllableSession( sess )
    if not sess.SupportsRemoteControl then return false, 1 end
    local client = tostring( sess.Client or "" ):lower()
    if client:match( "^vera emby" ) then return false, 2 end
    return true
end

local function updateSessions( server, taskid )
    assert(taskid)
    local anyPlaying = false
    local ok, data, httpstat = serverRequest( "GET", "/Sessions", nil, nil, nil, server )
    if not ok then
        luup.set_failure( 1, server )
        if httpstat == 401 then
            -- Auth fail, can't recover.
            setVar( SERVERSID, "Message", "Auth fail; re-do login.", server )
            L({level=1,msg="Authentication failure with %1 (#%2). Redo login to obtain new token."},
                luup.devices[server].description, server)
            return
        end
        D("updateSessions() failed session query for %1", server)
        local lastup = getVarNumeric( "LastUpdate", 0, server, SERVERSID )
        local delta = os.time() - lastup
        if delta < 120 then
            setVar( SERVERSID, "Message", "Unreachable; retrying...", server )
        else
            clearServerSessions( server )
            setVar( SERVERSID, "Message", "Down since " .. os.date("%x %X", lastup), server )
        end
        if delta >= 600 then L({level=2,msg="%1 (%2) unreachable since %3."}, luup.devices[server].description, server, os.date("%x %X", lastup)) end
        scheduleDelay( taskid, (delta >= 600) and 120 or 30 )
        return
    else
        luup.set_failure( 0, server )
        setVar( SERVERSID, "LastUpdate", os.time(), server )
        -- Create a map of child sessions for this server.
        local cs = getChildDevices( SESSIONTYPE, nil, function( dev, _ )
            local ps = getVarNumeric( "Server", 0, dev, SESSIONSID )
            return ps == server
        end )
        local childSessions = map( cs, function( obj ) return luup.devices[obj].id end )
        -- Iterate over response data
        D("updateSessions() server returned %1 sessions", #(data or {}))
        for _,sess in ipairs( data or {} ) do
            if isControllableSession( sess ) then
                D("updateSessions() updating session %1 (%2)", sess.DeviceName, sess.Id)
                local child = childSessions[ sess.Id ]
                if child then
-- luup.log(json.encode(sess),2)
                    childSessions[ sess.Id  ] = nil
                    updateSession( sess, child, server )
                    anyPlaying = anyPlaying or ( sess.NowPlayingItem ~= nil )
                    local show = luup.variable_get( SESSIONSID, "Visibility", child ) or ""
                    if string.find(":show:hide:", show) then
                        luup.attr_set( "invisible", ( show == "hide" ) and "1" or "0", child )
                    elseif getVarNumeric( "HideIdle", 0, server, SERVERSID ) ~= 0 then
                        luup.attr_set( "invisible", ( sess.NowPlayingItem == nil ) and "1" or "0", child )
                    else
                        luup.attr_set( "invisible", "0", child )
                    end
                else
                    L({level=2,msg="Child device not found for session %1 (%2) on %3 (%4), a %5 %6; you may need to run inventory on this server, or the child is not supported."},
                        sess.Id, sess.DeviceName, luup.devices[server].description, server,
                        sess.Client, sess.ApplicationVersion)
                end
            end
        end
        for k,v in pairs( childSessions ) do
            D("updateSessions() clearing offline session %1 (dev #%2 %3)", k,
                v, (luup.devices[v] or {}).description)
            if setVar( SESSIONSID, "Offline", 1, v ) ~= "1" then
                L({level=3,msg="Marking %1 (%2) offline (server return no data for active session request)"},
                    (luup.devices[v] or {}).description, v)
            end
            clearPlayingState( v )
            setVar( SESSIONSID, "DisplayStatus", "Offline", v )
            local show = luup.variable_get( SESSIONSID, "Visibility",  v ) or ""
            if string.find(":show:hide:", show) then
                luup.attr_set( "invisible", ( show == "hide" ) and "1" or "0", v )
            elseif getVarNumeric( "HideOffline", 0, server, SERVERSID ) ~= 0 then
                luup.attr_set( "invisible", "1", v )
            else
                luup.attr_set( "invisible", "0", v )
            end
        end
    end

    -- If not playing and haven't played in 60 seconds, idle back.
    local now = os.time()
    local lastPlaying = getVarNumeric( "LastPlaying", 0, server, SERVERSID )
    D("updateSession() server %1 lastPlaying %2 now %3 anyPlaying %4", server, lastPlaying, now, anyPlaying)
    local idleTick = ( not anyPlaying ) and ( lastPlaying < (now-60) )
    if anyPlaying then setVar( SERVERSID, "LastPlaying", now, server ) end

    -- Reschedule for update -- ??? TIMING FIXME?
    setVar( SERVERSID, "Message", idleTick and "Idle" or "Active", server )
    local delay = getVarNumeric( idleTick and "SessionUpdateIntervalIdle" or "SessionUpdateIntervalPlaying", idleTick and 60 or 5, server, SERVERSID )
    scheduleDelay( taskid, delay )
end

handleIncomingMessage = function( op, msg, server )
    D("handleIncomingMessage(%1,%2 bytes,%3)", op, #msg, server)
    if op == 9 then return end -- ping
    if debugMode and #msg > 0 then luup.log( msg:gsub( "(%c)", function( c ) return string.format("%%%02x", string.byte(c)) end ), 2 ) end
    if not ( op == 1 ) then
        D("handleIncomingMessage() don't know how to handle opcode %1", op)
        return
    end

    local anyPlaying = false
    local data,pos,err = json.decode( msg )
    if not data or err then
        D("handleIncomingMessage() invalid data received, %1 at %2", err, pos)
        if debugMode then luup.log( msg, 2 ) end
        return
    end
    if data.MessageType ~= "Sessions" then
        D("handleIncomingMessage() can't handle incoming message type %1", data.MessageType)
        return
    end

    -- Run with it!
    data = data.Data

    luup.set_failure( 0, server )
    setVar( SERVERSID, "LastUpdate", os.time(), server )

    -- Create a map of child sessions for this server.
    local cs = getChildDevices( SESSIONTYPE, nil, function( dev, devobj )
        local ps = getVarNumeric( "Server", 0, dev, SESSIONSID )
        return ps == server
    end )
    local childSessions = map( cs, function( obj ) return luup.devices[obj].id end )

    -- Iterate over data
    D("updateSessions() server returned %1 sessions", #(data or {}))
    for _,sess in ipairs( data or {} ) do
        if isControllableSession( sess ) then
            D("updateSessions() updating session %1 (%2)", sess.DeviceName, sess.Id)
            local child = childSessions[ sess.Id ]
            if child then
-- luup.log(json.encode(sess),2)
                childSessions[ sess.Id  ] = nil
                updateSession( sess, child, server )
                anyPlaying = anyPlaying or ( sess.NowPlayingItem ~= nil )
                local show = luup.variable_get( SESSIONSID, "Visibility", child ) or ""
                if string.find(":show:hide:", show) then
                    luup.attr_set( "invisible", ( show == "hide" ) and "1" or "0", child )
                elseif getVarNumeric( "HideIdle", 0, server, SERVERSID ) ~= 0 then
                    luup.attr_set( "invisible", ( sess.NowPlayingItem == nil ) and "1" or "0", child )
                else
                    luup.attr_set( "invisible", "0", child )
                end
            else
                L({level=2,msg="Child device not found for session %1 (%2) on %3 (%4), a %5 %6; you may need to run inventory on this server, or the child is not supported."},
                    sess.Id, sess.DeviceName, luup.devices[server].description, server,
                    sess.Client, sess.ApplicationVersion)
            end
        end
    end
    for k,v in pairs( childSessions ) do
        D("updateSessions() clearing offline session %1 (dev #%2 %3)", k,
            v, (luup.devices[v] or {}).description)
        if setVar( SESSIONSID, "Offline", 1, v ) ~= "1" then
            L({level=3,msg="Marking %1 (%2) offline (server return no data for active session request)"},
                (luup.devices[v] or {}).description, v)
        end
        clearPlayingState( v )
        setVar( SESSIONSID, "DisplayStatus", "Offline", v )
        local show = luup.variable_get( SESSIONSID, "Visibility",  v ) or ""
        if string.find(":show:hide:", show) then
            luup.attr_set( "invisible", ( show == "hide" ) and "1" or "0", v )
        elseif getVarNumeric( "HideOffline", 0, server, SERVERSID ) ~= 0 then
            luup.attr_set( "invisible", "1", v )
        else
            luup.attr_set( "invisible", "0", v )
        end
    end

    -- Defer update
    scheduleDelay( tostring(server), 120 )
end

-- Inventory sessions using local server request
local function inventorySessions( server )
    L("Launching session inventory for %1 (%2)", luup.devices[server].description, server)
    local ok, data, httpstat = serverRequest( "GET", "/Sessions", nil, nil, nil, server )
    if not ok then
        D("inventorySessions() failed session query for %1, will retry...", server)
        luup.set_failure( 1, server )
        if httpstat == 401 then
            -- Auth fail, can't recover.
            clearServerSessions( server )
            setVar( SERVERSID, "Message", "Auth fail; re-do login.", server )
            L({level=1,msg="Authentication failure with %1 (#%2). Redo login to obtain new token."},
                luup.devices[server].description, server)
            return
        end
        L({level=2,msg="Server unreachable for session inventory (%1). Scheduling retry."}, httpstat)
        setVar( SERVERSID, "Message", "Unreachable; retrying...", server )
        scheduleDelay( { id=tostring(server), owner=server, info="inventoryretry", func=inventorySessions }, 120 )
        return
    else
        luup.set_failure( 0, server )
        -- Returns array (hopefully) of sessions (as dev nums) belonging to this server.
        local cs = getChildDevices( SESSIONTYPE, nil, function( dev, _ )
            local ps = getVarNumeric( "Server", 0, dev, SESSIONSID )
            return ps == server
        end )
        -- Create map
        local childSessions = map( cs, function( obj ) return luup.devices[obj].id end )
        D("inventorySessions() childSessions=%1", childSessions)
        local newSessions = {}
        for _,sess in ipairs( data or {} ) do
            if not isControllableSession( sess ) then
                L("Session %1 (%2) client %3 version %4, not supported (skipped)",
                    sess.DeviceName, sess.Id, sess.Client, sess.ApplicationVersion)
            else
                local child = childSessions[ sess.Id ]
                if not child then
                    L("New session %1 (%2), client %3 version %4 (will be added)",
                        sess.DeviceName, sess.Id, sess.Client, sess.ApplicationVersion)
                    table.insert( newSessions, sess )
                else
                    L("Existing session %1 (%2), client %3 version %4 (updating)",
                        sess.DeviceName, sess.Id, sess.Client, sess.ApplicationVersion)
                    childSessions[ sess.Id ] = nil -- remove from map
                    initSession( child )
                    updateSession( sess, child, server )
                end
            end
        end

        -- Anything left in map wasn't returned by query, so assume offline.
        for k,v in pairs( childSessions ) do
            L("Session %3 (dev #%2, id %1) missing from server response; marking offline.",
                k, v, (luup.devices[v] or {}).description)
            clearPlayingState( v )
            setVar( SESSIONSID, "Offline", 1, v )
            setVar( SESSIONSID, "DisplayStatus", "Offline", v )
            if getVarNumeric( "HideOffline", 0, server, SERVERSID ) ~= 0 then
                luup.attr_set( "invisible", "1", v )
            end
        end

        -- If we have newly discovered sessions, add them as children (causes Luup restart)
        if #newSessions > 0 then
            addEvent{ dev=server, event="inventory", new=#newSessions }
            L({level=2,msg="Discovered %1 new sessions on %2 (#%3), adding and restarting..."}, #newSessions,
                luup.devices[server].description, server)
            local ptr = prepForNewChildren()
            -- Create children for newly-discovered session(s)
            for _,sess in ipairs( newSessions ) do
                L("Appending session %1 (%2) client %3", sess.DeviceName, sess.Id, sess.Client)
                luup.chdev.append( pluginDevice, ptr, sess.Id, sess.DeviceName or sess.Id, "",
                    "D_EmbySession1.xml",
                    "",
                    SESSIONSID .. ",Server="..server,
                    false )
            end
            -- Finished
            L({level=2,msg="New sessions have been created for %1 (%2), a Luup reload will occur!"},
                luup.devices[server].description, server)
            luup.chdev.sync( pluginDevice, ptr ) -- should reload
        end
    end
end

-- One-time init for server
local function initServer( server )
    D("initServer(%1)", server)
    initVar( "Message", "", server, SERVERSID )
    initVar( "LastUpdate", "0", server, SERVERSID )
    initVar( "APIKey", "", server, SERVERSID )
    initVar( "UserId", "", server, SERVERSID )
    initVar( "SessionUpdateIntervalIdle", "", server, SERVERSID )
    initVar( "SessionUpdateIntervalPlaying", "", server, SERVERSID )
    initVar( "SmartSkipDefault", "", server, SERVERSID )
    initVar( "SmartSkipGrace", "", server, SERVERSID )
    initVar( "HideOffline", "0", server, SERVERSID )
    initVar( "HideIdle", "0", server, SERVERSID )

    if getVarNumeric( "Version", 0, server, SERVERSID ) < 000101 then
        luup.attr_set( 'category_num', 1, server )
    end
    setVar( SERVERSID, "Version", _CONFIGVERSION, server )
end

local function launchUpdate( server, task )
    D("launchUpdate(%1,%2)", server, task)
    if luup.is_ready( server ) then
        wssend( 1, { MessageType="SessionsStart", Data="5000,5000" }, server )
        local ra,rb,rc,rd = luup.call_action( SERVERSID, "Update", {}, server )
        D("launchUpdate() return from Update action %1,%2,%3,%4", ra,rb,rc,rd)
    else
        D("launchUpdate() server %1 not ready, waiting", server)
        scheduleDelay( task, 5 )
    end
end

-- Start server
local function startServer( server )
    D("startServer(%1)", server)
    local apikey = luup.variable_get( SERVERSID, "APIKey", server ) or ""
    if string.find( apikey, "^[xX]*$" ) then
        addEvent{ dev=server, event="startfail", reason="Not authenticated" }
        setVar( SERVERSID, "Message", "Please log in.", server )
        luup.set_failure( 1, server )
        return
    end

    local ok, data, httpstat = serverRequest( "GET", "/System/Info", nil, nil, nil, server )
    if not ok then
        luup.set_failure( 1, server )
        if httpstat == 401 then
            addEvent{ dev=server, event="startfail", reason="Invalid auth data" }
            setVar( SERVERSID, "Message", "Can't authenticate. Check API Key.", server )
            luup.set_failure( 1, server )
        else
            addEvent{ dev=server, event="startfail", reason="Query fail: "..tostring(httpstat) }
            setVar( SERVERSID, "Message", "Can't get system data (" .. tostring(httpstat) .. "), will retry later", server )
            scheduleDelay( { id=tostring(server), info="deferstart", owner=server, func=startServer }, getVarNumeric( "RetryInterval", 120, pluginDevice, MYSID ) )
        end
    else
        -- Do something...
        setVar( SERVERSID, "ServerName", data.ServerName or "", server )
        setVar( SERVERSID, "Version", data.Version or "", server )
        setVar( SERVERSID, "Platform", data.OperatingSystemDisplayName or data.OperatingSystem, server )
        setVar( SERVERSID, "OS", data.OperatingSystem, server )
        local okmsg = string.format("Version %s on %s", data.Version or "?", data.OperatingSystem or "?")
        local id = luup.attr_get( "altid", server )
        if data.Id and id ~= data.Id then
            addEvent{ dev=server, event="startfail", reason="Server ID changed from "..tostring(id).." to "..tostring(data.Id) }
            L({level=2,msg="Emby server at %1 ID changed, was %2 now %3, repairing..."}, data.ServerName, id, data.Id)
            setVar( SERVERSID, "Message", "ID mismatch; attempting repair.", server )
            luup.set_failure( 1, server )
            luup.attr_set( "altid", data.Id, server )
            luup.reload()
            return
        end

        -- Check server software version
        local pt = split( tostring(data.Version or ""), "%." )
        local rev = (tonumber(pt[1]) or 0) + (tonumber(pt[2]) or 0) / 10
        D("startServer() checking server %1 software rev %2", data.ServerName, rev)
        if rev < 3.4 then
            L({level=1,msg="Emby server %1 unsupported; please upgrade to 3.4 or higher."}, data.ServerName)
            addEvent{ dev=server, event="startfail", reason="Server version unsupported " .. tostring(data.Version) }
            setVar( SERVERSID, "Message", "Server version unsupported", server )
            luup.set_failure( 1, server )
            return
        end

        -- Launch!
        addEvent{ dev=server, event="start", message="Successful startup" }
        luup.set_failure( 0, server )
        if getVarNumeric( "StartupInventory", 1, pluginDevice, MYSID ) ~= 0 then
            setVar( SERVERSID, "Message", "Taking session inventory...", server )
            inventorySessions( server )
        end

        -- Launch websocket
        local addr = luup.variable_get( SERVERSID, "LocalAddress", server ) or "http://127.0.0.1:8096"
        wsopen( addr, server )
        if wsconnect( server ) then
            -- scheduleDelay( { id=tostring(server), owner=server, info="sessionupdate", func=updateSessions }, 120 )
            D("startServer() server %1 successful WebSocket startup", server)
            scheduleDelay( { id=tostring(server), owner=server, info="launchupdate", func=launchUpdate }, 5 )
        else
            L({level=1,msg="Server %1 failed to open WebSocket; falling back to polling."}, server)
            scheduleDelay( { id=tostring(server), owner=server, info="sessionupdate", func=updateSessions }, 15 )
        end

        setVar( SERVERSID, "Message", okmsg, server )
    end
end

-- Check servers
local function startServers( dev )
    D("startServers()")
    local servers = getChildDevices( SERVERTYPE, dev )
    for _,server in ipairs( servers ) do
        luup.variable_set( SERVERSID, "Message", "Starting...", server)

        initServer( server )

        startServer( server )
    end
end

--[[
    D I S C O V E R Y   A N D   C O N N E C T I O N
--]]

local function askLuci(p)
    D("askLuci(%1)", p)
    local uci = require("uci")
    if uci then
        local ctx = uci.cursor(nil, "/var/state")
        if ctx then
            return ctx:get(unpack((split(p,"%."))))
        else
            D("askLuci() can't get context")
        end
    else
        D("askLuci() no UCI module")
    end
    return nil
end

-- Query UCI for WAN IP4 IP
local function getSystemIP4Addr( dev ) -- luacheck: ignore 212
    local vera_ip = askLuci("network.wan.ipaddr")
    D("getSystemIP4Addr() got %1 from Luci", vera_ip)
    if not vera_ip then
        -- Fallback method
        local p = io.popen("/usr/bin/GetNetworkState.sh wan_ip")
        vera_ip = p:read("*a") or ""
        p:close()
        D("getSystemIP4Addr() got system ip4addr %1 using fallback", vera_ip)
    end
    return vera_ip:gsub("%c","")
end

-- Query UCI for WAN IP4 netmask
local function getSystemIP4Mask( dev ) -- luacheck: ignore 212
    local mask = askLuci("network.wan.netmask");
    D("getSystemIP4Mask() got %1 from Luci", mask)
    if not mask then
        -- Fallback method
        local p = io.popen("/usr/bin/GetNetworkState.sh wan_netmask")
        mask = p:read("*a") or ""
        p:close()
        D("getSystemIP4Addr() got system ip4mask %1 using fallback", mask)
    end
    return mask:gsub("%c","")
end

-- Compute broadcast address (IP4)
local function getSystemIP4BCast( dev )
    local broadcast = luup.variable_get( MYSID, "DiscoveryBroadcast", dev ) or ""
    if broadcast ~= "" then
        return broadcast
    end

    if isOpenLuup then
        gatewayStatus( "openLuup must set DiscoveryBroadcast first" )
        error("You must set DiscoveryBroadcast in the Emby Plugin device to your network broadcast address.")
    end

    -- Do it the hard way.
    local vera_ip = getSystemIP4Addr( dev )
    local mask = getSystemIP4Mask( dev )
    D("getSystemIP4BCast() sys ip %1 netmask %2", vera_ip, mask)
    local a1,a2,a3,a4 = vera_ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)")
    local m1,m2,m3,m4 = mask:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)")
    -- Yeah. This is my jam, baby!
    a1 = bit.bor(bit.band(a1,m1), bit.bxor(m1,255))
    a2 = bit.bor(bit.band(a2,m1), bit.bxor(m2,255))
    a3 = bit.bor(bit.band(a3,m3), bit.bxor(m3,255))
    a4 = bit.bor(bit.band(a4,m4), bit.bxor(m4,255))
    broadcast = string.format("%d.%d.%d.%d", a1, a2, a3, a4)
    D("getSystemIP4BCast() computed broadcast address is %1", broadcast)
    return broadcast
end

-- Process discovery responses
local function processDiscoveryResponses( dev )
    if #(devData[tostring(dev)].discoveryResponses or {}) < 1 then
        return
    end

    for _,ndev in ipairs(devData[tostring(dev)].discoveryResponses) do
        if not ndev.Id then
        end
    end

    local ptr,existing = prepForNewChildren()
    local seen = map( existing, function( n ) return luup.devices[n].id end )
    local hasNew = false
    for _,ndev in ipairs(devData[tostring(dev)].discoveryResponses) do
        if not seen[ndev.Id] then
            L("Adding %1...", ndev.Name or ndev.Address)
            luup.chdev.append( pluginDevice, ptr,
                ndev.Id or ndev.Address, -- id (altid)
                ndev.Name or ("Server@"..ndev.Address), -- description
                "", -- device type
                "D_EmbyServer1.xml", -- device file
                "", -- impl file
                SERVERSID .. ",LocalAddress=" .. ndev.Address, -- state vars
                false -- embedded
            )
            hasNew = true
        end
    end

    -- Close children. This will cause a Luup reload if something changed.
    if hasNew then
        L("New server(s) added, reload coming!")
        gatewayStatus("New server(s) added, reloading...")
    else
        gatewayStatus("No new servers discovered.")
    end
    luup.chdev.sync( pluginDevice, ptr )
end

-- Handle discovery message
local function handleDiscoveryMessage( response, dev )
    local data,pos,err = json.decode( response )
    if data == nil or err then
        D("handleDiscoveryMessage() JSON error at %1: %2", pos, err)
        D("handleDiscoveryMessage() ignoring unparseable response: %1", response)
    elseif data.Address ~= nil and data.Id ~= nil and data.Name ~= nil then
        devData[tostring(dev)].discoveryResponses = devData[tostring(dev)].discoveryResponses or {}
        table.insert( devData[tostring(dev)].discoveryResponses, data )
    else
        D("handleDiscoveryMessage() ignoring non-compliant response: %1", response)
    end
end

-- Tick for UDP discovery.
local function udpDiscoveryTask( dev, taskid )
    D("udpDiscoveryTask(%1,%2)", dev, taskid)

    local rem = math.max( 0, devData[tostring(dev)].discoveryTime - os.time() )
    gatewayStatus( string.format( "Discovery running, found %d so far (%d%%)...",
        #(devData[tostring(dev)].discoveryResponses), math.floor((DISCOVERYPERIOD-rem)/DISCOVERYPERIOD*100)) )

    local udp = devData[tostring(dev)].discoverySocket
    if udp ~= nil then
        repeat
            udp:settimeout(1)
            local resp, peer, port = udp:receivefrom()
            if resp ~= nil then
                D("udpDiscoveryTask() received response from %1:%2", peer, port)
                if string.find( resp, "who is EmbyServer?" ) then
                    -- Huh. There's an echo.
                else
                    handleDiscoveryMessage( resp, dev )
                end
            end
        until resp == nil

        if os.time() < devData[tostring(dev)].discoveryTime then
            scheduleDelay( taskid, 1 )
            return
        else
            scheduleTick( taskid, 0 ) -- remove task
        end
        udp:close()
        devData[tostring(dev)].discoverySocket = nil
        devData[tostring(dev)].discoveryTime = nil
    end
    D("udpDiscoveryTask() end of discovery")
    processDiscoveryResponses( dev )
end

-- Launch UDP discovery.
local function launchUDPDiscovery( dev )
    D("launchUDPDiscovery(%1)", dev)
    assert(dev ~= nil)
    assert(luup.devices[dev].device_type == MYTYPE, "Discovery much be launched with gateway device")

    -- Configure
    local addr = getSystemIP4BCast( dev )
    local port = 7359

    -- Any of this can fail, and it's OK.
    local udp = socket.udp()
    udp:setoption('broadcast', true)
    udp:setoption('dontroute', true)
    udp:setsockname('*', port)
    D("launchUDPDiscovery() sending discovery request")
    local stat,err = udp:sendto( "who is EmbyServer?", addr, port)
    if stat == nil then
        gatewayStatus("Discovery failed! " .. tostring(err))
        L("Failed to send discovery req: %1", err)
        return
    end

    devData[tostring(dev)].discoverySocket = udp
    local now = os.time()
    devData[tostring(dev)].discoveryTime = now + DISCOVERYPERIOD
    devData[tostring(dev)].discoveryResponses = {}

    scheduleDelay( { id="discovery-"..dev, func=udpDiscoveryTask, owner=dev }, 1 )
    gatewayStatus( "Discovery running..." )
end

--[[
local function embyUserRequest( path, args, hh, dev, method )
    method = method or "GET"
    local headers = hh and shallowCopy(hh) or {}
    headers['X-Connect-UserToken'] = luup.variable_get( MYSID, "ConnectAccessToken", dev ) or ""
    local ea = {}
    for k,v in pairs(args) do
        table.insert( ea, k .. "=" .. urlencode(tostring(v)) )
    end
    local encargs = table.concat( ea, "&" )
    local success, resp, httpstat = doRequest( method, "https://connect.emby.media/service" .. path .. "?" .. encargs, headers, nil, dev )
    if success then
        local data,pos,err = json.decode( resp )
        if not err then
            return true, data, 200
        end
        return false, nil, 500
    end
    return success, resp, httpstat
end
--]]

--[[
local function embyListServers( dev )
    assert(cui) -- we have work to do, this is a reminder
    local success, data, httpstat = embyUserRequest( "/servers", { userId=cui }, nil, dev )
    D("embyListServers() response data is %1", data)
    for _,server in ipairs(data) do
        -- See if child found with matching SystemId
        -- If not, add to list of servers to be added
        -- Remove from list of servers to be deleted.
    end
    -- If there are servers to be deleted, remove them.
    -- If there are servers to be added, add them.
    error("No implementation yet")
end
--]]

-- Log in to server with username/password. Returns auth token, which we store.
--[[ This is another one of those things where the documentation is loose on a
     process that requires perfection. Swagger to the rescue. Here's what worked:
    curl -X POST "http://192.168.0.165:8096/emby/Users/AuthenticateByName" -H "accept: application/json" -H "X-Emby-Authorization: MediaBrowser Client="Vera", Device="Vera", DeviceId="123", Version="1.0.0.0"" -H "Content-Type: application/json" -d "{ \"Username\": \"patrick\", \"Pw\": \"\", \"Password\": \"\", \"PasswordMd5\", \"\"}"
    Note that the contents of the X-Emby-Authorization header are tightly
    checked (each required), but the values are just for show. Go figure. As of
    April 2018, apparently, we only need to pass Pw in the data; the other
    forms of password aren't needed.
--]]
local function embyServerLogin( username, password, dev )
    assert(dev ~= nil and luup.devices[dev].device_type == SERVERTYPE)
    setVar( SERVERSID, "Message", "Requesting auth...", dev)
    local addr = luup.variable_get( SERVERSID, "LocalAddress", dev )
    local req = addr .. "/emby/Users/AuthenticateByName"
    local success, response, httpStatus = doRequest( "POST", req,
        { ['X-Emby-Authorization']="MediaBrowser Client=\"Vera Emby Plugin\", Device=\"Vera-"..luup.pk_accesspoint.."\", DeviceId=\""..luup.pk_accesspoint.."\", Version=\"".._PLUGIN_VERSION.."\"" },
        { Username=username, Pw=password }, dev )
    if success then
        local data, pos, err = json.decode( response )
        if not err then
            -- Successful auth, so store the new user id and api key
            L({level=2,msg="Successful login on %2 (%1) for user %3"}, luup.devices[dev].description, dev, username)
            setVar( SERVERSID, "Message", "Successful authorization!", dev)
            setVar( SERVERSID, "UserId", data.User.Id, dev )
            setVar( SERVERSID, "APIKey", data.AccessToken, dev )
            scheduleDelay( { id=tostring(dev), owner=dev, func=startServer }, 3 ) -- (re)start server
            return
        else
            D("embyLocalLogin() unparseable response at %1, %2: %3", pos, err, response)
        end
    elseif httpStatus == 401 then
        L({level=2,msg="Login failed on %1 (%2) for user %3"}, luup.devices[dev].description, dev, username)
        setVar( SERVERSID, "Message", "Invalid username/password", dev)
        return
    else
        L({level=2,msg="Authorization request to %1 (%2) failed: %3"}, luup.devices[dev].description, dev, httpStatus)
    end
    setVar( SERVERSID, "Message", "Authorization request failed", dev)
end

--[[
local function embyRemoteLogin( username, password, dev )
    local success, response, httpStatus = doRequest( "POST", "https://connect.emby.media/service/user/authenticate", {},
        { nameOrEmail=username or "", rawpw=password or ""}, dev )
    if success then
        local data,pos,err = json.decode( response )
        if not err then
            setVar( MYSID, "ConnectAccessToken", data.ConnectAccessToken or "", dev )
            setVar( MYSID, "ConnectUserId", data.ConnectUserId or "", dev )
            inventoryServers( dev )
        else
            gatewayStatus("Login error!")
        end
    else
        gatewayStatus("Login failed!")
    end
end
--]]

--[[
    ***************************************************************************
    A C T I O N   I M P L E M E N T A T I O N
    ***************************************************************************
--]]

--[[ Issue command for session. Structure is bizarre, and Emby's remote API
     docs are wrong, incomplete, and less than useless. I would not have figured
     out how to get this working had it not been for the genius on their team
     who made the interactive API browser, which with a bit of fiddling, reveals
     the secret incantations... kudos, mate, whoever you are. You da real MVP.
--]]
function actionSessionGeneralCommand( pdev, actionpath, args )
    assert(luup.devices[pdev].device_type==SESSIONTYPE)
    local sess = luup.devices[pdev].id
    local server = getVarNumeric( "Server", 0, pdev, SESSIONSID )
    local reqpath = "/Sessions/" .. sess .. "/Command" .. (actionpath or "")
    serverRequest( "POST", reqpath, nil, nil, args, server )
    scheduleDelay( tostring(server), 2 )
end

function actionSessionPlayCommand( pdev, actionpath, args )
    assert(luup.devices[pdev].device_type==SESSIONTYPE)
    local sess = luup.devices[pdev].id
    local server = getVarNumeric( "Server", 0, pdev, SESSIONSID )
    local reqpath = "/Sessions/" .. sess .. "/Playing" .. (actionpath or "")
    local ok = serverRequest( "POST", reqpath, nil, nil, args, server )
    if ok then
        scheduleDelay( tostring(server), 2 )
    end
    return ok
end

function actionSessionMessage( pdev, message, title, timeout )
    assert(luup.devices[pdev].device_type==SESSIONTYPE)
    local sess = luup.devices[pdev].id
    local server = getVarNumeric( "Server", 0, pdev, SESSIONSID )
    local reqpath = "/Sessions/" .. sess .. "/Message"
    local params = { Header=title or "", Text=message or "" }
    if (timeout or "") ~= "" then params.TimeoutMs = timeout end
    local ok = serverRequest( "POST", reqpath, params, nil, nil, server )
    return ok
end

function actionSessionViewMedia( pdev, id, title, mediatype )
    assert(luup.devices[pdev].device_type==SESSIONTYPE)
    local sess = luup.devices[pdev].id
    local server = getVarNumeric( "Server", 0, pdev, SESSIONSID )
    local reqpath = "/Sessions/" .. sess .. "/Viewing"
    local params = { ItemId=id, ItemName=title, ItemType=mediatype }
    local ok = serverRequest( "POST", reqpath, params, nil, nil, server )
    return ok
end

function actionSessionRefresh( pdev )
    assert(luup.devices[pdev].device_type==SESSIONTYPE)
    local server = getVarNumeric( "Server", 0, pdev, SESSIONSID )
    scheduleDelay( tostring(server), 1 )
end

-- Login in to server with username/password
function actionServerLogin( pdev, username, password )
    assert(luup.devices[pdev].device_type == SERVERTYPE) -- must be Emby gateway
    return embyServerLogin( username, password, pdev )
end

-- Play media; see the README/docs
function actionSessionPlayMedia( pdev, argv )
    assert(luup.devices[pdev].device_type==SESSIONTYPE)
    local sess = luup.devices[pdev].id
    local server = getVarNumeric( "Server", 0, pdev, SESSIONSID )
    local ids
    if (argv.Id or "") ~= "" then
        ids = argv.Id
    else
        -- Ids not passed; we need to search. First, get items for user,
        -- restrict by media type if given.
        local userid = luup.variable_get( SERVERSID, "UserId", server ) or ""
        local reqpath
        if userid ~= "" then
            reqpath = "/Users/" .. userid .. "/Items"
        else
            reqpath = "/Items"
        end
        local limit = tonumber( argv.Limit or "25" ) or 0
        limit = (limit>0) and limit or 25 -- 0 means default 25
        local ea = { Recursive=true, Fields="Path", IncludeMedia=true,
            IncludePeople=false, IncludeGenres=false, IncludeStudios=false,
            IncludeArtists=false, EnableImages=false, EnableUserData=false,
            Limit=limit } -- StartIndex=0
        if (argv.MediaType or "") ~= "" then
            ea.IncludeItemTypes = argv.MediaType == "*" and "" or argv.MediaType
        else
            local mts = luup.variable_get( SESSIONSID, "PlayableMediaTypes", pdev ) or ""
            if mts ~= "" then
                ea.IncludeItemTypes = argv.mts
            end
        end
        ea.searchTerm = argv.Title or "``````"
        local il = {}
        local ok, data, httpstat = serverRequest( "GET", reqpath, ea, nil, nil, server )
        if not ok then
            L({level=2,msg="Media query failed (%1); path %2 params %3"}, httpstat, reqpath, ea)
            return false
        end
        -- OK. Now go through items to find those that match. Stack em up.
        D("actionSessionPlayMedia() evaluating %1 matches of %2", #data.Items, data.TotalRecordCount)
        for _,item in ipairs( data.Items or {} ) do
            table.insert( il, item.Id )
        end
        L("%1 (%2) PlayMedia found %3", luup.devices[pdev].description, pdev, data.TotalRecordCount or #il)
        ids = table.concat( il, "," )
    end
    local cmd = argv.PlayCommand or "PlayNow"
    L("%1 (%2) %3 %4", luup.devices[pdev].description, pdev, cmd, ids)
    local ea = { ItemIds=ids, PlayCommand=cmd }
    local ok, _, httpstat = serverRequest( "POST", "/Sessions/" .. sess .. "/Playing",
        ea, nil, nil, server )
    if ok then
        scheduleDelay( tostring(server), 2 )
    else
        L({level=2,msg="%1 (%2) PlayMedia play request failed (%3)"},
            luup.devices[pdev].description, pdev, httpstat)
    end
    return ok
end

function actionSessionResumeMedia( pdev, restart )
    assert(luup.devices[pdev].device_type==SESSIONTYPE)
    local sess = luup.devices[pdev].id
    local server = getVarNumeric( "Server", 0, pdev, SESSIONSID )
    local state = luup.variable_get( SESSIONSID, "TransportState", pdev ) or ""
    if state == "STOPPED" then
        state = luup.variable_get( SESSIONSID, "ResumePoint", pdev ) or ""
        state = split( state )
        if #state == 2 then
            local ea = { ItemIds=state[1], PlayCommand="PlayNow" }
            if not restart then ea.StartPositionTicks = tonumber( state[2] ) or 0 end
            local ok, _, httpstat = serverRequest( "POST", "/Sessions/" .. sess .. "/Playing",
                ea, nil, nil, server )
            if ok then
                L("%1 (%2) ResumeMedia OK, ItemId=%3 StartPositionTicks=%4",
                    luup.devices[pdev].description, pdev, state[1],
                    restart and "restart" or state[2])
                scheduleDelay( tostring(server), 2 )
                return true
            end
            L({level=2,msg="%1 (%2) ResumeMedia server request failed (%3)"},
                luup.devices[pdev].description, pdev, httpstat)
        else
            L({level=2,msg="%1 (%2) can't ResumeMedia, no checkpoint."},
                luup.devices[pdev].description, pdev )
        end
    else
        L({level=2,msg="%1 (%2) can't ResumeMedia, already playing (%3)"},
            luup.devices[pdev].description, pdev, state)
    end
    return false
end

--[[ "SmartSkip". The Emby RemoteControl API has NextTrack/PreviousTrack, and
     these work as expected for audio play, but at least in the Android and
     Chrome apps, they do not chapter skip video. Hmmm. OK, so this "SmartSkip"
     looks at the current playing media type, and either uses the built-in
     track controls, or uses the chapter data to do seek. --]]
function actionSessionSmartSkip( pdev, backwards )
    assert(luup.devices[pdev].device_type == SESSIONTYPE) -- must be Emby gateway
    local server = getVarNumeric( "Server", 0, pdev, SESSIONSID )
    local mt = (luup.variable_get( SESSIONSID, "PlayingItemMediaType", pdev ) or ""):lower()
    if mt == "" then
        -- Not playing anything.
        return
    elseif mt == "video" then
        -- First, get current play position
        local pos = getVarNumeric( "PlayingItemPosition", 0, pdev, SESSIONSID )
        local pend = getVarNumeric( "PlayingItemRuntime", 0, pdev, SESSIONSID )
        local ch = luup.variable_get( SESSIONSID, "PlayingItemChapters", pdev ) or ""
        local data = json.decode( ch )
        D("actionSessionSmartSkip() backwards=%1, position=%2, chapters=%3", backwards, pos, data)
        local destpos
        if data then
            if not backwards then
                destpos = pend * 10000000
                for _,v in ipairs(data) do
                    local chpos = math.floor( v.StartPositionTicks / 10000 ) / 1000
                    if chpos > pos then
                        destpos = v.StartPositionTicks
                        break
                    end
                end
            else
                destpos = 0
                local grace = getVarNumeric( "SmartSkipGrace", getVarNumeric( "SmartSkipGrace", 5, server, SERVERSID ), pdev, SESSIONSID )
                for ix=#data,1,-1 do
                    local v = data[ix]
                    local chpos = math.floor( v.StartPositionTicks / 10000 ) / 1000
                    if (chpos + grace) < pos then
                        destpos = v.StartPositionTicks
                        break
                    end
                end
            end
        else
            -- No chapter data, just X-second skip; skip can be session-specific or server default (30).
            local skip = getVarNumeric( "SmartSkipDefault", getVarNumeric( "SmartSkipDefault", 30, server, SERVERSID ), pdev, SESSIONSID )
            destpos = pos + skip * (backwards and -1 or 1)
            if destpos < 0 then destpos = 0 elseif destpos > pend then destpos = pend end
            destpos = destpos * 10000000
        end
        --[[ Oh, and another fucking surprise ending. Emby's remote control docs for seek are wrong, too. Again, swagger to the rescue. --]]
        local sess = luup.devices[pdev].id
        local reqpath = "/Sessions/" .. sess .. "/Playing/Seek"
        local ok = serverRequest( "POST", reqpath, nil, nil, { Command="Seek", SeekPositionTicks=destpos }, server )
        if ok then
            scheduleDelay( tostring(server), 2 )
        end
    else
        -- Default to track commands for all other media types.
        local cmd = backwards and "/PreviousTrack" or "/NextTrack"
        return actionSessionPlayCommand( pdev, cmd )
    end
end

--[[ "SmartMute" -- three different ways to get mute done: /ToggleMute command
     (if/when it works), SetVolume (0/current), or Pause.
     If toggle is true, mute state toggles and state is ignored. Otherwise,
     state sets mute (true=mute).
--]]
function actionSessionSmartMute( pdev, toggle, state )
    D("actionSessionSmartMute(%1,%2,%3)", pdev, toggle, state)
    assert(luup.devices[pdev].device_type == SESSIONTYPE) -- must be Emby gateway
    local smc = string.lower( luup.variable_get( SESSIONSID, "SmartMute", pdev ) or "" )
    local mute = getVarNumeric( "Mute", 0, pdev, "urn:micasaverde-com:serviceId:Volume1" )
    if smc == "" or string.find( ":default:0:", smc ) then
        -- SmartMute default: figure out what works.
        local cmdMute = isSessionCommandSupported( "ToggleMute", pdev ) or ( isSessionCommandSupported( "Mute", pdev ) and isSessionCommandSupported( "Unmute", pdev ) )
        if not cmdMute then
            -- Don't have ToggleMute or Mute/Unmute pair.
            if isSessionCommandSupported( "SetVolume", pdev ) then
                smc = "volume"
            else
                smc = "pause"
            end
        else
            smc = "command"
        end
        D("actionSessionSmartMute() determined best mute method is %1", smc)
    end
    if smc == "pause" then
        if toggle then
            local ts = luup.variable_get( SESSIONSID, "TransportState", pdev ) or "STOPPED"
            state = not (ts == "PAUSED")
        end
        D("actionSessionSmartMute() play/pause mute, target mute=%1", state)
        -- Pause/unpause based on state
        return actionSessionPlayCommand( pdev, state and "/Pause" or "/Unpause" )
    elseif smc == "volume" or ( smc ~= "" and smc ~= "0" ) then
        -- Volume control
        if not isSessionCommandSupported( "SetVolume", pdev ) then
            L({level=2,msg="%1 (%2) does not support SetVolume; try \"pause\" SmartMute configuration."},
                luup.devices[pdev].description, pdev)
            return
        end
        local vn = getVarNumeric( "VolumePercent", 0, pdev, SESSIONSID )
        if toggle then
            state = vn ~= 0 -- 0=muted, so state=opposite
        end
        D("actionSessionSmartMute() volume control mute, current %1, target mute=%2", vn, state)
        if state then
            -- Save current volume level
            if vn > 0 then
                setVar( SESSIONSID, "SmartMuteSavedLevel", vn, pdev )
            end
            vn = 0
        else
            vn = getVarNumeric( "SmartMuteSavedLevel", vn, pdev, SESSIONSID )
            setVar( SESSIONSID, "SmartMuteSavedLevel", 0, pdev )
        end
        return actionSessionGeneralCommand( pdev, nil,
                    { Name="SetVolume", Arguments={ Volume=tostring(vn) } } )
    else
        -- Use commands
        D("actionSessionSmartMute() API standard command mute, current mute=%1", mute)
        if toggle then
            if isSessionCommandSupported( "ToggleMute", pdev ) then
                return actionSessionGeneralCommand( pdev, "/ToggleMute" )
            end
            -- ToggleMute isn't supported, so fall back to direct Mute/Unmute (hopefully)
            state = mute == 0
        end
        D("actionSessionSmartMute() target mute=%1", state)
        if state then
            -- Mute
            if isSessionCommandSupported( "Mute", pdev ) then
                return actionSessionGeneralCommand( pdev, "/Mute" )
            elseif isSessionCommandSupported( "ToggleMute", pdev ) then
                -- Use ToggleMute if not muted
                if mute == 0 then
                    return actionSessionGeneralCommand( pdev, "/ToggleMute" )
                end
            else
                L({level=2,msg="%1 (%2) does not support ToggleMute, Mute or Unmute; try configuring SmartMute."},
                    luup.devices[pdev].description, pdev)
            end
        else
            if isSessionCommandSupported( "Unmute", pdev ) then
                return actionSessionGeneralCommand( pdev, "/Unmute" )
            elseif isSessionCommandSupported( "ToggleMute", pdev ) then
                -- Use ToggleMute if muted
                if mute ~= 0 then
                    return actionSessionGeneralCommand( pdev, "/ToggleMute" )
                end
            else
                L({level=2,msg="%1 (%2) does not support ToggleMute, Mute or Unmute; try configuring SmartMute."},
                    luup.devices[pdev].description, pdev)
            end
        end
    end
end

function jobServerInventory( pdev )
    assert( luup.devices[pdev].device_type == SERVERTYPE )
    L("Inventory %1 (%2)", luup.devices[pdev].description, pdev)
    setVar( SERVERSID, "Message", "Taking inventory...", pdev )
    scheduleTick( tostring(pdev), 0 ) -- kill existing server task
    inventorySessions( pdev )
    return 4,0
end

-- Run Emby discovery (UDP broadcast port 7359)
function jobRunDiscovery( pdev )
    if isOpenLuup then
        gatewayStatus( "UDP discovery not available on openLuup; use IP discovery" )
        return 2,0
    end
    launchUDPDiscovery( pdev )
    return 4,0
end

-- IP discovery. Connect/query, and if we succeed, add.
function jobDiscoverIP( pdev, addr )
    if devData[tostring(pdev)].discoverySocket then
        L{level=2,msg="UDP discovery running, can't do direct IP discovery"}
        return 2,0
    end
    -- Clean and canonicalize
    addr = string.gsub( string.gsub( tostring(addr or ""), "^%s+", "" ), "%s+$", "" )
    if addr == "" then return 2,0 end
    if not string.find( addr, "^[Hh][Tt][Tt][Pp][Ss]?://" ) then
        addr = "http://" .. addr
    end
    addr = string.gsub( addr, "/+$", "" )
    if not string.find( addr, ":(%d+)$" ) then
        addr = addr .. ":8096"
    end
    L("Attempting direct IP discovery at %1", addr)
    gatewayStatus("Contacting " .. addr)
    local ok, resp, httpstat = doRequest( "GET", addr .. "/emby/System/Info/Public", nil, nil, pdev )
    if ok then
        local data,_,err = json.decode( resp )
        if not err then
            gatewayStatus("Found " .. data.ServerName .. " (" .. data.Id .. ")")
            devData[tostring(pdev)].discoveryResponses = { { Address=addr, Name=data.ServerName, Id=data.Id } }
            processDiscoveryResponses( pdev )
            return 4,0
        else
            L({level=2,msg="Unparsable response from %1"}, addr)
        end
    else
        L({level=2,msg="Info request failed from %1 (%2)"}, addr, httpstat)
    end
    L{level=2,msg="Direct IP discovery failed."}
    gatewayStatus("Direct IP discovery failed.")
    return 2,0
end

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

-- Dangerous debug stuff. Remove all child devices except servers.
function actionClear1( dev )
    local ptr = luup.chdev.start( dev )
    for _,v in pairs(luup.devices) do
        if v.device_num_parent == dev and v.device_type == SERVERTYPE then
            luup.chdev.append( dev, ptr, v.id, v.description, "",
                "D_EmbyServer1.xml", "", "", false )
        end
    end
    luup.chdev.sync( dev, ptr )
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
    if s ~= 0 and s == _CONFIGVERSION then
        -- Up to date.
        return
    elseif s == 0 then
        L("First run, setting up new plugin instance...")
        initVar( "Message", "", pdev, MYSID )
        initVar( "Enabled", "1", pdev, MYSID )
        initVar( "StartupInventory", "1", pdev, MYSID )
        initVar( "DebugMode", 0, pdev, MYSID )
        initVar( "DiscoveryBroadcast", "", pdev, MYSID )

        luup.attr_set('category_num', 1, pdev)

        luup.variable_set( MYSID, "Version", _CONFIGVERSION, pdev )
        return
    end

    -- Consider per-version changes.

    -- Update version last.
    if s ~= _CONFIGVERSION then
        luup.variable_set( MYSID, "Version", _CONFIGVERSION, pdev )
    end

    if s < 000100 then
        deferClear = true
    end
end

-- Tick handler for master device
local function masterTick(pdev,taskid)
    D("masterTick(%1,%2)", pdev,taskid)
    assert(pdev == pluginDevice)
    -- Set default time for next master tick
    local nextTick = math.floor( os.time() / 60 + 1 ) * 60

    -- Do master tick work here
    if deferClear then
        deferClear = false
        luup.call_action( MYSID, "Clear1", {}, pdev )
    end

    -- Schedule next master tick.
    scheduleTick( taskid, nextTick )
end

-- Start plugin running.
function startPlugin( pdev )
    L("plugin version %2, device %1 (%3)", pdev, _PLUGIN_VERSION, luup.devices[pdev].description)

    luup.variable_set( MYSID, "Message", "Initializing...", pdev )

    -- Early inits
firstbyte = true -- ???
    pluginDevice = pdev
    isALTUI = false
    isOpenLuup = false
    tickTasks = {}
    devData[tostring(pdev)] = {}
    maxEvents = getVarNumeric( "MaxEvents", 50, pdev, MYSID )

    -- Debug?
    if getVarNumeric( "DebugMode", 0, pdev, MYSID ) ~= 0 then
        debugMode = true
        D("startPlugin() debug enabled by state variable DebugMode")
    end

    -- Check for ALTUI and OpenLuup
    local failmsg = false
    for k,v in pairs(luup.devices) do
        if v.device_type == "urn:schemas-upnp-org:device:altui:1" and v.device_num_parent == 0 then
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
    local enabled = isEnabled( pdev )
    for _,d in ipairs( getChildDevices( nil, pdev ) or {} ) do
        luup.attr_set( 'invisible', enabled and 0 or 1, d )
    end
    luup.attr_set( 'invisible', 0, pdev )
    if not enabled then
        L{level=2,msg="disabled (see Enabled state variable)"}
        clearChildren( pdev )
        gatewayStatus("DISABLED")
        return true, "Disabled", _PLUGIN_NAME
    end

    -- Initialize and start the plugin timer and master tick
    runStamp = 1
    scheduleDelay( { id="master", func=masterTick, owner=pdev }, 5 )

    -- Start servers
    startServers( pdev )

    -- Return success
    gatewayStatus( nil )
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

    if not isEnabled( pluginDevice ) then
        clearChildren( pluginDevice )
        gatewayStatus( "DISABLED" )
        return
    end

    local now = os.time()
    local nextTick = nil
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

    -- Have we been disabled?
    if not isEnabled( pluginDevice ) then
        gatewayStatus("DISABLED")
        return
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
    local deviceNum = tonumber( lul_parameters['device'], 10 ) -- luacheck: ignore 211
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
            if v.device_type == MYTYPE or v.device_num_parent == pluginDevice then
                local devinfo = getDevice( k, pluginDevice, v ) or {}
                if k == pluginDevice then
                    devinfo.tickTasks = tickTasks
                    devinfo.devData = devData
                end
                if devData[tostring(k)] and devData[tostring(k)].eventList then
                    devinfo.eventList = devData[tostring(k)].eventList
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
