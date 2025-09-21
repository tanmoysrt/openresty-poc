local cjson = require "cjson"
local resty_balancer = require "ngx.balancer"

local _M = {}

function _M.init()
    ngx.log(ngx.INFO, "Initialized")
end

function _M.get_upstream_pool()
    local host = ngx.var.host or "default"
    return host
end

-- Helper function to get host and upstream from URI
local function parse_uri()
    local uri = ngx.var.uri
    local host, upstream = uri:match("^/hosts/([^/]+)/upstreams/([^/]+)$")
    if not host or not upstream then
        local host_only = uri:match("^/hosts/([^/]+)/upstreams$")
        if host_only then
            return host_only, nil
        end
    end
    return host, upstream
end

local function send_json_response(data, status)
    status = status or 200
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode(data))
    ngx.exit(status)
end

local function get_host_upstreams(host)
    local upstreams_dict = ngx.shared.upstreams
    ngx.log(ngx.INFO, "Fetching upstreams for host: " .. host)
    -- Print all keys in the shared dictionary for debugging
    local keys = upstreams_dict:get_keys(0)
    ngx.log(ngx.INFO, "Current keys in upstreams dict: " .. table.concat(keys, ", "))
    local encoded_upstreams = upstreams_dict:get(host)

    if not encoded_upstreams then
        return {}
    end

    local success, upstreams = pcall(cjson.decode, encoded_upstreams)
    if not success then
        ngx.log(ngx.ERR, "Failed to decode upstreams for host: " .. host)
        return {}
    end

    return upstreams
end

-- Helper function to set upstreams for a host
local function set_host_upstreams(host, upstreams)
    local upstreams_dict = ngx.shared.upstreams
    local encoded = cjson.encode(upstreams)
    local success, err = upstreams_dict:set(host, encoded)

    if not success then
        ngx.log(ngx.ERR, "Failed to store upstreams for host " .. host .. ": " .. (err or "unknown error"))
        return false
    end

    return true
end

-- Add upstream endpoint
function _M.add_upstream()
    local host, upstream = parse_uri()

    local upstreams = get_host_upstreams(host)

    -- Check if exists
    if upstreams[upstream] then
        send_json_response({
            success = false,
            message = "Upstream '" .. upstream .. "' already exists for host '" .. host .. "'"
        }, 409)
        return
    end

    -- Add new upstream
    upstreams[upstream] = { healthy = true, weight = 1 }

    -- Store back in shared dictionary
    if not set_host_upstreams(host, upstreams) then
        send_json_response({
            success = false,
            message = "Failed to store upstream configuration"
        }, 500)
        return
    end

    ngx.log(ngx.INFO, "Added upstream " .. upstream .. " to host " .. host)

    send_json_response({
        success = true,
        message = "Upstream '" .. upstream .. "' added to host '" .. host .. "'",
        data = {
            host = host,
            upstream = upstream,
            healthy = true,
            weight = 1
        }
    })
end

-- Remove upstream endpoint
function _M.remove_upstream()
    local host, upstream = parse_uri()

    if not host or not upstream then
        send_json_response({
            success = false,
            message = "Invalid URI format"
        }, 400)
        return
    end

    -- Get current upstreams for this host
    local upstreams = get_host_upstreams(host)

    -- Check if exists
    if not upstreams[upstream] then
        send_json_response({
            success = false,
            message = "Upstream '" .. upstream .. "' not found for host '" .. host .. "'"
        }, 404)
        return
    end

    -- Remove upstream
    upstreams[upstream] = nil

    -- Store back in shared dictionary
    if not set_host_upstreams(host, upstreams) then
        send_json_response({
            success = false,
            message = "Failed to store upstream configuration"
        }, 500)
        return
    end

    ngx.log(ngx.INFO, "Removed upstream " .. upstream .. " from host " .. host)

    send_json_response({
        success = true,
        message = "Upstream '" .. upstream .. "' removed from host '" .. host .. "'"
    })
end

-- Load balancer function (used in balancer_by_lua_block)
function _M.balance()
    local host = ngx.var.host or "default"
    local upstreams = get_host_upstreams(host)

    local healthy_upstreams = {}
    for addr, config in pairs(upstreams) do
        if config.healthy then
            table.insert(healthy_upstreams, addr)
        end
    end

    if #healthy_upstreams == 0 then
        ngx.log(ngx.INFO, "No healthy upstreams")
        return
    end

    -- Simple round-robin selection
    local round_robin_dict = ngx.shared.round_robin_state
    local current_index = round_robin_dict:get(host) or 1
    local selected_index = ((current_index - 1) % #healthy_upstreams) + 1
    local selected_upstream = healthy_upstreams[selected_index]

    -- Update round-robin index for next request
    round_robin_dict:set(host, selected_index + 1)

    -- Parse selected upstream
    local ip, port = selected_upstream:match("^([^:]+):(%d+)$")

    ngx.log(ngx.INFO, "Selected upstream for host " .. host .. ": " .. selected_upstream)

    -- Set the selected upstream server
    local balancer = resty_balancer
    ngx.log(ngx.INFO, "Setting current peer to " .. ip .. " port : " .. port)
    local ok, err = balancer.set_current_peer(ip, tonumber(port))
    if not ok then
        ngx.log(ngx.ERR, "Failed to set current peer: " .. (err or "unknown error"))
        return
    end
end

return _M
