--[[

    Part of AREDN® -- Used for creating Amateur Radio Emergency Data Networks
    Copyright (C) 2024 Tim Wilkinson
    See Contributors file for additional contributors

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation version 3 of the License.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

    Additional Terms:

    Additional use restrictions exist on the AREDN® trademark and logo.
        See AREDNLicense.txt for more info.

    Attributions to the AREDN® Project must be retained in the source code.
    If importing this code into a new or existing project attribution
    to the AREDN® project must be added to the source code.

    You must not misrepresent the origin of the material contained within.

    Modified versions must be modified to attribute to the original source
    and be marked in reasonable ways as differentiate it from the original
    version

--]]

local app = {}
local TTYS = {
    "/dev/ttyACM0",
    "/dev/ttyUSB0"
}
local CONFIG0 = "/etc/config.mesh/gpsd"
local CONFIG1 = "/etc/config/gpsd"
local CHANGEMARGIN = 0.0001

local function find_gps()
    for _, tty in ipairs(TTYS)
    do
        if nixio.fs.stat(tty) then
            return tty
        end
    end
    local l = io.open("/tmp/lqm.info")
    if l then
        local lqm = luci.jsonc.parse(l:read("*a"))
        l:close()
        for _, tracker in pairs(lqm.trackers)
        do
            if tracker.type == "DtD" and tracker.ip then
                local s = nixio.socket("inet", "stream")
                s:setopt("socket", "sndtimeo", 1)
                local r = s:connect(tracker.ip, 2947)
                s:close()
                if r then
                    return tracker.ip .. ":2947"
                end
            end
        end
    end
end

function app.whereandwhen()

    wait_for_ticks(60)

    local tty
    while true
    do
        tty = find_gps()
        if tty then
            break
        end
        wait_for_ticks(600) -- 10 minutes
    end

    -- Create the GPSD daemon if device is local,
    -- otherwise we get the GPS info from another node on our local network
    if tty:match("^/dev/") then
        local f = io.open(CONFIG0, "w")
        f:write(
[[config gpsd 'core'
    option enabled '1'
    option device ']] .. tty .. [['
    option port '2947'
    option listen_globally '1'
]])
        f:close()
        filecopy(CONFIG0, CONFIG1, true)
        os.execute("nft insert rule ip fw4 input_dtdlink tcp dport 2947 accept comment \"gpsd\" 2> /dev/null")
        os.execute("/etc/init.d/gpsd restart")
        tty = "127.0.0.1:2947"
    end

    while true
    do
        local done = false
        for line in io.popen("/usr/bin/gpspipe -w -n 10 " .. tty):lines()
        do
            if not done and line:match("TPV") then
                local j = luci.jsonc.parse(line)

                -- Set time and date
                local time = j.time:gsub("T", " "):gsub(".000Z", "")
                os.execute("/bin/date -u -s '" .. time .. "' > /dev/nul 2>&1")
                write_all("/tmp/timesync", "gps")

                -- Set location if significantly changed
                local lat = j.lat
                local lon = j.lon
                local c = uci.cursor()
                local clat = tonumber(c:get("aredn", "@location[0]", "lat") or 0)
                local clon = tonumber(c:get("aredn", "@location[0]", "lon") or 0)
                if math.abs(clat - lat) > CHANGEMARGIN or math.abs(clon - lon) > CHANGEMARGIN then
                    -- Calculate gridsquare from lat/lon
                    local alat = lat + 90
                    local flat = 65 + math.floor(alat / 10)
                    local slat = math.floor(alat % 10)
                    local ulat = 97 + math.floor((alat - math.floor(alat)) * 60 / 2.5)

                    local alon = lon + 180
                    local flon = 65 + math.floor(alon / 20)
                    local slon = math.floor((alon / 2) % 10)
                    local ulon = 97 + math.floor((alon - 2 * math.floor(alon / 2)) * 60 / 5)

                    local gridsquare = string.format("%c%c%d%d%c%c", flon, flat, slon, slat, ulon, ulat)

                    -- Update location information
                    c:set("aredn", "@location[0]", "lat", lat)
                    c:set("aredn", "@location[0]", "lon", lon)
                    c:set("aredn", "@location[0]", "gridsquare", gridsquare)
                    c:set("aredn", "@location[0]", "source", "gps")
                    c:commit("aredn")
                    local cm = uci.cursor("/etc/config.mesh")
                    cm:set("aredn", "@location[0]", "lat", lat)
                    cm:set("aredn", "@location[0]", "lon", lon)
                    cm:set("aredn", "@location[0]", "gridsquare", gridsquare)
                    cm:set("aredn", "@location[0]", "source", "gps")
                    cm:commit("aredn")
                end
                done = true
            end
        end

        wait_for_ticks(600) -- 10 minutes
    end
end

return app.whereandwhen
