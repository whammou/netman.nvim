-- WebDAV provider for netman.nvim
-- Supports dav:// (HTTP) and davs:// (HTTPS) WebDAV protocols
-- Requires: curl
--
-- URI format: dav[s]://[user[:password]@]host[:port]/[path]
--
-- Examples:
--   dav://localhost/path/to/file.txt        (HTTP, port 80)
--   davs://example.com:8443/path/           (HTTPS, port 8443)
--   dav://user@host:8080/path/              (with auth)
--   davs://user:pass@host/path/file.txt     (with basic auth)

local metadata_options = require("netman.tools.options").explorer.METADATA
local api_flags = require("netman.tools.options").api
local ui_states = require("netman.tools.options").ui.STATES
local string_generator = require("netman.tools.utils").generate_string
local shell = require("netman.tools.shell")
local command_flags = shell.CONSTANTS.FLAGS
local local_files = require("netman.tools.utils").files_dir
local utils = require("netman.tools.utils")
local CACHE = require("netman.tools.cache")

local logger = require("netman.tools.utils").get_provider_logger()

local M = {
    name = 'webdav',
    version = 1.0,
    protocol_patterns = { 'dav', 'davs' },
    internal = {},
    ui = {},
    archive = {}
}

M.ui.icon = "🌐"
local success, web_devicons = pcall(require, "nvim-web-devicons")
if success then
    local devicon, _ = web_devicons.get_icon('globe')
    M.ui.icon = devicon or M.ui.icon
end

--- Parses the raw XML response from a PROPFIND request into a table
--- of response entries. Each entry contains href and properties.
--- Handles the DAV: namespace regardless of prefix (D:, d:, etc.)
--- @param xml string The raw PROPFIND XML response
--- @return table List of response entries, each with href, props table
local function parse_propfind_xml(xml)
    local entries = {}
    if not xml then return entries end
    if type(xml) == 'table' then xml = table.concat(xml, '') end
    if xml:len() == 0 then return entries end

    -- Strip XML declaration and namespace noise for easier matching
    -- Extract each <D:response>...</D:response> block (case-insensitive on namespace)
    local response_pattern = '<[%Dd][%w_]*:[Rr]esponse[^>]*>(.-)</[%Dd][%w_]*:[Rr]esponse>'
    for response_block in xml:gmatch(response_pattern) do
        local entry = { props = {} }

        -- Extract href
        local href = response_block:match('<[%Dd][%w_]*:[Hh]ref[^>]*>(.-)</[%Dd][%w_]*:[Hh]ref>')
        if href then
            -- Decode URL-encoded characters
            href = href:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
            entry.href = href
        end

        -- Extract propstat block
        local propstat = response_block:match('<[%Dd][%w_]*:[Pp]ropstat[^>]*>(.-)</[%Dd][%w_]*:[Pp]ropstat>')
        if propstat then
            -- Extract prop block
            local prop = propstat:match('<[%Dd][%w_]*:[Pp]rop[^>]*>(.-)</[%Dd][%w_]*:[Pp]rop>')
            if prop then
                -- resourcetype: check for collection element
                local rt = prop:match('<[%Dd][%w_]*:[Rr]esourcetype[^>]*>(.-)</[%Dd][%w_]*:[Rr]esourcetype>')
                if rt then
                    entry.props.is_collection = rt:match('<[%Dd][%w_]*:[Cc]ollection') ~= nil
                end

                -- getcontentlength
                local len = prop:match('<[%Dd][%w_]*:[Gg]etcontentlength[^>]*>(.-)</[%Dd][%w_]*:[Gg]etcontentlength>')
                if len then entry.props.content_length = tonumber(len) or 0 end

                -- getlastmodified
                entry.props.last_modified = prop:match('<[%Dd][%w_]*:[Gg]etlastmodified[^>]*>(.-)</[%Dd][%w_]*:[Gg]etlastmodified>') or ''

                -- creationdate
                entry.props.creation_date = prop:match('<[%Dd][%w_]*:[Cc]reationdate[^>]*>(.-)</[%Dd][%w_]*:[Cc]reationdate>') or ''

                -- displayname
                entry.props.display_name = prop:match('<[%Dd][%w_]*:[Dd]isplayname[^>]*>(.-)</[%Dd][%w_]*:[Dd]isplayname>') or ''

                -- getcontenttype
                entry.props.content_type = prop:match('<[%Dd][%w_]*:[Gg]etcontenttype[^>]*>(.-)</[%Dd][%w_]*:[Gg]etcontenttype>') or ''

                -- getetag
                entry.props.etag = prop:match('<[%Dd][%w_]*:[Gg]etetag[^>]*>(.-)</[%Dd][%w_]*:[Gg]etetag>') or ''
            end

            -- Status
            entry.status = propstat:match('<[%Dd][%w_]*:[Ss]tatus[^>]*>(.-)</[%Dd][%w_]*:[Ss]tatus>') or ''
        end

        table.insert(entries, entry)
    end

    return entries
end

--- The WebDAV connection object. An abstraction layer over a specific
--- WebDAV host/endpoint.
local WebDAV = {
    CONSTANTS = {
        IO_BYTE_LIMIT = 2 ^ 13,
        MKDIR_UNKNOWN_ERROR = 'mkdir failed with unknown error',
        STAT_FLAGS = {
            ABSOLUTE_PATH = 'ABSOLUTE_PATH',
            MODE = 'MODE',
            BLOCKS = 'BLOCKS',
            BLKSIZE = 'BLKSIZE',
            MTIME_SEC = 'MTIME_SEC',
            USER = 'USER',
            GROUP = 'GROUP',
            INODE = 'INODE',
            PERMISSIONS = 'PERMISSIONS',
            SIZE = 'SIZE',
            TYPE = 'TYPE',
            NAME = 'NAME',
            URI = 'URI'
        }
    },
    internal = {}
}

local URI = {}
M.internal.WebDAV = WebDAV
M.internal.URI = URI

--- Creates a new WebDAV connection object
--- @param auth_details table|string
---     Authentication details as a table or URI string
--- @param provider_cache cache
---     The netman api provided cache
function WebDAV:new(auth_details, provider_cache)
    assert(auth_details, "No authorization details provided for new webdav object. h: netman.provider.webdav.new")
    assert(provider_cache, "No cache provided for WebDAV object. h: netman.providers.webdav.new")
    assert(utils.os_has('curl'), "curl not available on this system! WebDAV provider requires curl")

    if type(auth_details) == 'string' then
        local new_auth_details = URI:new(auth_details, provider_cache)
        assert(new_auth_details,
            string.format("Unable to parse %s into a valid WebDAV URI. h: netman.providers.webdav.new", auth_details))
        auth_details = new_auth_details
    end

    local cache_key = string.format("%s://%s@%s:%s",
        auth_details.protocol,
        auth_details.user or '',
        auth_details.host or '',
        auth_details.port or '')
    if provider_cache:get_item(cache_key) then
        return provider_cache:get_item(cache_key)
    end

    local _webdav = {}
    _webdav.protocol = auth_details.protocol or 'dav'
    _webdav._auth_details = auth_details
    _webdav.host = auth_details.host or 'localhost'
    _webdav.port = auth_details.port or (_webdav.protocol == 'davs' and 443 or 80)
    _webdav.user = auth_details.user or ''
    _webdav.pass = auth_details.password or ''
    _webdav.__type = 'netman_provider_webdav'
    _webdav.cache = CACHE:new(CACHE.FOREVER)

    -- Build the base URL, including any subpath from the URI (e.g. /remote.php/dav/files/user)
    local base_path = ''
    if auth_details.path and #auth_details.path > 0 then
        local filtered = {}
        for _, part in ipairs(auth_details.path) do
            if part ~= '/' then table.insert(filtered, part) end
        end
        if #filtered > 0 then
            base_path = '/' .. table.concat(filtered, '/')
        end
    end
    -- Map dav/davs → http/https for curl (curl does not understand dav:// scheme)
    local http_protocol = _webdav.protocol == 'davs' and 'https' or 'http'
    _webdav.base_url = string.format("%s://%s:%s%s", http_protocol, _webdav.host, _webdav.port, base_path)

    -- Build base curl command with common flags
    -- -s: silent, -g: disable URL globbing (for brackets in paths), --fail: fail on HTTP errors
    _webdav.base_curl = { 'curl', '-s', '-g', '--fail' }
    if _webdav.user:len() > 0 then
        local userpass = _webdav.user
        if _webdav.pass:len() > 0 then
            userpass = string.format("%s:%s", _webdav.user, _webdav.pass)
        end
        table.insert(_webdav.base_curl, '--user')
        table.insert(_webdav.base_curl, userpass)
    end

    -- Allow self-signed certs for davs://
    if _webdav.protocol == 'davs' then
        table.insert(_webdav.base_curl, '--insecure')
    end

    setmetatable(_webdav, self)
    self.__index = self
    provider_cache:add_item(cache_key, _webdav)
    return _webdav
end

--- Builds a full URL from a path
--- @param path string The path to append to the base URL
function WebDAV:build_url(path)
    if not path or path:len() == 0 then path = '/' end
    -- Ensure path starts with /
    if path:sub(1, 1) ~= '/' then path = '/' .. path end
    return self.base_url .. path
end

--- Runs a shell command (used for curl)
--- @param command table The command to run (list of args)
--- @param opts table|nil Options for the shell
function WebDAV:run_command(command, opts)
    opts = vim.tbl_extend("force", {
        [command_flags.STDOUT_JOIN] = '',
        [command_flags.STDERR_JOIN] = ''
    }, opts or {})
    local _shell = shell:new(command, opts)
    local _shell_output = _shell:run()
    logger.trace(_shell:dump_self_to_table())
    return _shell_output
end

--- Executes a WebDAV HTTP request via curl
--- @param method string HTTP method (GET, PUT, DELETE, PROPFIND, MKCOL, MOVE, COPY)
--- @param path string The URL path to operate on
--- @param opts table|nil Options table with keys:
---     - depth: string (for PROPFIND, default "0")
---     - file: string (for PUT, path to local file to upload)
---     - data: string (for PUT, raw data to upload when no file)
---     - destination: string (for MOVE/COPY, destination URL)
---     - output_file: string (for GET, where to save the response body)
---     - headers: table (additional HTTP headers as {name, value, ...} pairs)
--- @return table Shell command result
function WebDAV:request(method, path, opts)
    opts = opts or {}
    local curl_cmd = {}

    -- Copy base curl command
    for _, v in ipairs(self.base_curl) do
        table.insert(curl_cmd, v)
    end

    local url = self:build_url(path)

    if method == 'PROPFIND' then
        table.insert(curl_cmd, '-X')
        table.insert(curl_cmd, 'PROPFIND')
        table.insert(curl_cmd, '-H')
        table.insert(curl_cmd, 'Depth: ' .. (opts.depth or '0'))
    elseif method == 'PUT' then
        table.insert(curl_cmd, '-X')
        table.insert(curl_cmd, 'PUT')
        if opts.file then
            -- Upload from a local file
            -- -T sends a PUT with the file contents
            table.insert(curl_cmd, '--data-binary')
            table.insert(curl_cmd, '@' .. opts.file)
        elseif opts.data then
            table.insert(curl_cmd, '--data-binary')
            table.insert(curl_cmd, opts.data)
        else
            -- Empty PUT
            table.insert(curl_cmd, '-H')
            table.insert(curl_cmd, 'Content-Length: 0')
        end
    elseif method == 'DELETE' then
        table.insert(curl_cmd, '-X')
        table.insert(curl_cmd, 'DELETE')
    elseif method == 'MKCOL' then
        table.insert(curl_cmd, '-X')
        table.insert(curl_cmd, 'MKCOL')
    elseif method == 'MOVE' then
        table.insert(curl_cmd, '-X')
        table.insert(curl_cmd, 'MOVE')
        table.insert(curl_cmd, '-H')
        table.insert(curl_cmd, string.format('Destination: %s', opts.destination or ''))
    elseif method == 'COPY' then
        table.insert(curl_cmd, '-X')
        table.insert(curl_cmd, 'COPY')
        table.insert(curl_cmd, '-H')
        table.insert(curl_cmd, string.format('Destination: %s', opts.destination or ''))
    end

    -- Additional headers
    if opts.headers then
        for i = 1, #opts.headers, 2 do
            table.insert(curl_cmd, '-H')
            table.insert(curl_cmd, string.format('%s: %s', opts.headers[i], opts.headers[i + 1]))
        end
    end

    -- Output file for GET responses
    if opts.output_file then
        table.insert(curl_cmd, '-o')
        table.insert(curl_cmd, opts.output_file)
    end

    table.insert(curl_cmd, url)

    logger.trace(string.format("WebDAV %s %s", method, url))
    return self:run_command(curl_cmd, opts)
end

--- Retrieves the stat/metadata of a path via PROPFIND
--- @param location string|URI The path to stat
--- @param target_flags table|nil Which stat flags to return
--- @return table Stat results keyed by path
function WebDAV:stat(location, target_flags)
    if type(location) ~= 'table' or #location == 0 then location = { location } end
    local return_data = {}

    for _, loc in ipairs(location) do
        if loc.__type and loc.__type == 'netman_uri' then
            loc = loc:to_string()
        end

        local response = self:request('PROPFIND', loc, { depth = '0' })
        if response.exit_code ~= 0 then
            logger.warn(string.format("Unable to stat %s", loc), { exit_code = response.exit_code, stderr = response.stderr })
            goto continue
        end

        local entries = parse_propfind_xml(response.stdout)
        for _, entry in ipairs(entries) do
            if entry.href then
                -- Normalize href: strip scheme+host if absolute URL
                local href_path = entry.href:match('^https?://[^/]+(/.*)') or entry.href
                -- With Depth:0, only the resource itself is returned.
                -- Match the entry whose path equals the requested location.
                local loc_normalized = loc:match('^https?://[^/]+(/.*)') or loc
                if href_path == loc_normalized or href_path == loc_normalized .. '/' then
                    local parsed = self:_parse_stat_entry(entry, target_flags)
                    if parsed then
                        return_data[parsed.ABSOLUTE_PATH or parsed.NAME] = parsed
                    end
                end
            end
        end
        ::continue::
    end

    return return_data
end

--- Parses a single PROPFIND response entry into the stat format
--- @param entry table The parsed PROPFIND entry
--- @param target_flags table|nil Which flags to include
function WebDAV:_parse_stat_entry(entry, target_flags)
    if not entry or not entry.href then return nil end

    local href = entry.href
    -- Normalize: strip trailing / for consistent matching
    local is_dir = entry.props.is_collection
    local name = entry.props.display_name or ''

    -- Extract name from href if displayname is empty
    if name:len() == 0 then
        local parts = {}
        for part in href:gmatch('[^/]+') do
            table.insert(parts, part)
        end
        name = parts[#parts] or href
    end

    -- Build the stat item
    local item = {}
    item[WebDAV.CONSTANTS.STAT_FLAGS.NAME] = name
    -- Build a full dav[s]:// URI so netman can re-route navigation through the provider
    item[WebDAV.CONSTANTS.STAT_FLAGS.URI] = string.format("%s://%s:%s%s", self.protocol, self.host, self.port, href)
    item[WebDAV.CONSTANTS.STAT_FLAGS.TYPE] = is_dir and 'directory' or 'regular file'
    item[WebDAV.CONSTANTS.STAT_FLAGS.SIZE] = tostring(entry.props.content_length or 0)

    -- Parse last modified into MTIME_SEC
    if entry.props.last_modified and entry.props.last_modified:len() > 0 then
        -- HTTP dates are complex, store as string for now
        item[WebDAV.CONSTANTS.STAT_FLAGS.MTIME_SEC] = entry.props.last_modified
    else
        item[WebDAV.CONSTANTS.STAT_FLAGS.MTIME_SEC] = '0'
    end

    -- WebDAV doesn't provide POSIX permissions, user/group, etc. Set defaults
    item[WebDAV.CONSTANTS.STAT_FLAGS.MODE] = is_dir and '16877' or '33188' -- 0755 dir / 0644 file
    item[WebDAV.CONSTANTS.STAT_FLAGS.PERMISSIONS] = is_dir and '755' or '644'
    item[WebDAV.CONSTANTS.STAT_FLAGS.USER] = ''
    item[WebDAV.CONSTANTS.STAT_FLAGS.GROUP] = ''
    item[WebDAV.CONSTANTS.STAT_FLAGS.INODE] = '0'
    item[WebDAV.CONSTANTS.STAT_FLAGS.BLOCKS] = '0'
    item[WebDAV.CONSTANTS.STAT_FLAGS.BLKSIZE] = '4096'

    -- FIELD_TYPE for explorer
    if is_dir then
        item['FIELD_TYPE'] = metadata_options.LINK
    else
        item['FIELD_TYPE'] = metadata_options.DESTINATION
    end

    -- Build ABSOLUTE_PATH (path breadcrumbs for the explorer)
    local path_parts = {}
    local cur_path = ''
    local href_normalized = href:gsub('^/', '')
    for part in href_normalized:gmatch('[^/]+') do
        cur_path = cur_path .. '/' .. part
        table.insert(path_parts, {
            uri = self.base_url .. cur_path .. (is_dir and '/' or ''),
            name = part
        })
    end
    if #path_parts == 0 then
        -- Root path
        table.insert(path_parts, { uri = self.base_url .. '/', name = '/' })
    end
    item[WebDAV.CONSTANTS.STAT_FLAGS.ABSOLUTE_PATH] = path_parts

    return item
end

--- Performs a PROPFIND with Depth:1 to list a directory
--- @param location string|URI The directory to list
--- @param opts table|nil Options (max_depth, etc.)
function WebDAV:find(location, opts)
    opts = opts or {}
    if location.__type and location.__type == 'netman_uri' then
        location = location:to_string()
    end

    local response = self:request('PROPFIND', location, { depth = '1' })
    if response.exit_code ~= 0 then
        return {
            error = response.stderr or 'Unknown error during PROPFIND'
        }
    end

    local entries = parse_propfind_xml(response.stdout)
    local children = {}

    for _, entry in ipairs(entries) do
        -- Skip the requested resource itself (Depth:1 returns parent + children)
        if entry.href and entry.href ~= location then
            local parsed = self:_parse_stat_entry(entry)
            if parsed then
                table.insert(children, parsed)
            end
        end
    end

    return children
end

--- Downloads a file from the server to a local path
--- @param location URI The remote path to download
--- @param output_dir string The local directory to save to
--- @param opts table|nil Options (new_file_name, async, finish_callback, ignore_errors)
function WebDAV:get(location, output_dir, opts)
    opts = opts or {}
    local return_details = {}
    assert(utils.os_has('curl'), "curl not available on this system!")

    if type(location) == 'string' then
        location = URI:new(location)
    end
    assert(location.__type and location.__type == 'netman_uri',
        string.format("%s is not a valid netman URI", location))

    local file_name = opts.new_file_name or location.path[#location.path] or 'download'
    local output_path = string.format("%s/%s", output_dir, file_name)

    local finish_callback = function(command_output)
        logger.trace(command_output)
        if command_output.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Unable to download %s", location:to_string())
            logger.warn(_error, { exit_code = command_output.exit_code, error = command_output.stderr })
            return_details = { error = command_output.stderr, success = false }
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        return_details = {
            success = true,
            data = {
                file = output_path
            }
        }
        if opts.finish_callback then opts.finish_callback(return_details) end
    end

    local command_options = {
        [command_flags.STDERR_JOIN] = '',
        [command_flags.EXIT_CALLBACK] = finish_callback,
        [command_flags.ASYNC] = opts.async and true or false
    }

    -- Use GET with output file
    local curl_cmd = {}
    for _, v in ipairs(self.base_curl) do
        table.insert(curl_cmd, v)
    end
    table.insert(curl_cmd, '-o')
    table.insert(curl_cmd, output_path)
    table.insert(curl_cmd, self:build_url(location:to_string()))

    command_options[command_flags.STDOUT_JOIN] = ''
    local run_details = shell:new(curl_cmd, command_options):run()
    if not opts.async then return return_details else return run_details end
end

--- Uploads a local file to the server via PUT
--- @param file string The local file path
--- @param location URI The remote destination
--- @param opts table|nil Options (new_file_name, async, finish_callback, ignore_errors)
function WebDAV:put(file, location, opts)
    opts = opts or {}
    local return_details = {}
    assert(utils.os_has('curl'), "curl not available on this system!")

    if type(location) == 'string' then
        location = URI:new(location)
    end
    assert(location.__type and location.__type == 'netman_uri',
        string.format("%s is not a valid netman URI", location))

    -- Ensure parent directory exists (MKCOL)
    local parent = location:parent()
    local mkdir_result = self:mkdir(parent)
    if mkdir_result.error and not opts.ignore_errors then
        -- Non-fatal, the PUT might still work even if mkdir fails
        logger.warn(string.format("Unable to ensure parent directory exists %s", parent:to_string()),
            { error = mkdir_result.error })
    end

    local file_name = opts.new_file_name or location.path[#location.path] or 'upload'
    local remote_path = location:to_string()

    -- If new_file_name is provided, append to parent path
    if opts.new_file_name then
        remote_path = string.format("%s/%s", parent:to_string(), opts.new_file_name)
    end

    local finish_callback = function(command_output)
        logger.trace(command_output)
        if command_output.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Unable to upload %s", file)
            logger.warn(_error, { exit_code = command_output.exit_code, error = command_output.stderr })
            return_details = { error = _error, success = false }
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        return_details = { success = true }
        if opts.finish_callback then opts.finish_callback(return_details) end
    end

    -- Build curl command for PUT
    local curl_cmd = {}
    for _, v in ipairs(self.base_curl) do
        table.insert(curl_cmd, v)
    end
    table.insert(curl_cmd, '-X')
    table.insert(curl_cmd, 'PUT')
    table.insert(curl_cmd, '--data-binary')
    table.insert(curl_cmd, '@' .. file)
    table.insert(curl_cmd, self:build_url(remote_path))

    local command_options = {
        [command_flags.STDOUT_JOIN] = '',
        [command_flags.STDERR_JOIN] = '',
        [command_flags.EXIT_CALLBACK] = finish_callback
    }
    if opts.async then
        command_options[command_flags.ASYNC] = true
    end

    local run_details = shell:new(curl_cmd, command_options):run()
    if not opts.async then return return_details else return run_details end
end

--- Creates a directory via MKCOL
--- @param locations table List of paths to create
--- @param opts table|nil Options (ignore_errors)
function WebDAV:mkdir(locations, opts)
    opts = opts or {}
    local return_data = nil
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end

    local __ = {}
    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then location = location:to_string() end
        table.insert(__, location)
    end
    locations = __

    for _, location in ipairs(locations) do
        local response = self:request('MKCOL', location)
        if response.exit_code ~= 0 and not opts.ignore_errors then
            -- 405/409 means the directory already exists, which is fine
            local stderr = response.stderr or ''
            if not stderr:match('405') and not stderr:match('409') and not stderr:match('already exists') then
                local _error = string.format("Unable to make %s", location)
                logger.warn(_error, { exit_code = response.exit_code, error = response.stderr })
                return_data = { success = false, error = _error }
                goto done
            end
        end
    end

    return_data = { success = true }
    ::done::
    return return_data
end

--- Removes a file or directory via DELETE
--- @param locations table List of paths to delete
--- @param opts table|nil Options (force, ignore_errors)
function WebDAV:rm(locations, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end

    for _, location in ipairs(locations) do
        if type(location) == 'string' then
            if not location:match('^davs?://') then
                -- URI coalescing: prefix with self protocol/host
                location = string.format('%s://%s:%s%s', self.protocol, self.host, self.port, location)
            end
            location = URI:new(location)
        end
        assert(location.__type and location.__type == 'netman_uri',
            string.format("%s is not a valid netman uri", location))

        local response = self:request('DELETE', location:to_string())
        if response.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Unable to remove %s", location:to_string())
            logger.error(_error, { exit_code = response.exit_code, error = response.stderr })
            return { success = false, error = _error }
        end
    end
    return { success = true }
end

--- Copies a file/directory via COPY
--- @param locations table List of source paths
--- @param target_location string Destination path
--- @param opts table|nil Options (ignore_errors)
function WebDAV:cp(locations, target_location, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    if target_location.__type and target_location.__type == 'netman_uri' then
        target_location = target_location:to_string()
    end

    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then
            location = location:to_string()
        end

        local dest_url = self:build_url(target_location)
        local response = self:request('COPY', location, { destination = dest_url })
        if response.exit_code ~= 0 and not opts.ignore_errors then
            local message = string.format("Unable to copy %s to %s", location, target_location)
            return { success = false, error = message }
        end
    end
    return { success = true }
end

--- Moves/renames a file/directory via MOVE
--- @param locations table List of source paths
--- @param target_location string Destination path
--- @param opts table|nil Options (ignore_errors)
function WebDAV:mv(locations, target_location, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    if target_location.__type and target_location.__type == 'netman_uri' then
        target_location = target_location:to_string()
    end

    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then
            location = location:to_string()
        end

        local dest_url = self:build_url(target_location)
        local response = self:request('MOVE', location, { destination = dest_url })
        if response.exit_code ~= 0 and not opts.ignore_errors then
            local message = string.format("Unable to move %s to %s", location, target_location)
            return { success = false, error = message }
        end
    end
    return { success = true }
end

--- Touches a file (creates empty file via PUT)
--- @param locations table List of paths to create
--- @param opts table|nil Options (ignore_errors)
function WebDAV:touch(locations, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end

    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then location = location:to_string() end

        local response = self:request('PUT', location, { data = '' })
        if response.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Unable to touch %s", location)
            logger.warn(_error, { exit_code = response.exit_code, error = response.stderr })
            return { success = false, error = _error }
        end
    end
    return { success = true }
end

--- URI Object functions
--------------------------------------
function URI:new(uri, cache)
    if cache and cache:get_item(uri) then return cache:get_item(uri) end

    local _uri = {}
    _uri.uri = uri

    -- Parse protocol (dav or davs)
    local protocol = uri:match('^(davs?)://')
    assert(protocol, string.format("Invalid WebDAV URI format: %s. Expected dav:// or davs://", uri))
    _uri.protocol = protocol

    -- Strip protocol
    local rest = uri:gsub('^davs?://', '')

    -- Parse user:password@host:port
    local userinfo = rest:match('^([^@/]+)@')
    if userinfo then
        local user, pass = userinfo:match('([^:]*):?(.*)')
        _uri.user = user or ''
        _uri.password = pass or ''
        rest = rest:gsub('^[^@]+@', '')
    else
        _uri.user = ''
        _uri.password = ''
    end

    -- Parse host:port
    _uri.host = rest:match('^([^:/]+)')
    assert(_uri.host, string.format("Invalid URI: %s Unable to parse host", uri))

    local port_str = rest:match('^[^:]+:([0-9]+)')
    _uri.port = port_str and tonumber(port_str) or (_uri.protocol == 'davs' and 443 or 80)

    -- Parse path
    local path_start = rest:match('^[^/]+(/.*)')
    _uri.path = {}
    if path_start and path_start:len() > 0 then
        for part in path_start:gmatch('([^/]+)') do
            table.insert(_uri.path, part)
        end
    end

    if not path_start or path_start == '/' then
        table.insert(_uri.path, '/')
    end

    -- Determine type
    if not path_start or path_start == '/' or path_start:sub(-1, -1) == '/' then
        _uri.type = api_flags.ATTRIBUTES.DIRECTORY
        _uri.return_type = api_flags.READ_TYPE.EXPLORE
    else
        _uri.type = api_flags.ATTRIBUTES.DESTINATION
        _uri.return_type = api_flags.READ_TYPE.FILE
        _uri.extension = (_uri.path[#_uri.path]:match('%..*$') or '')
        _uri.unique_name = string.format("%s%s", string_generator(11), _uri.extension)
    end

    _uri.__type = 'netman_uri'
    setmetatable(_uri, self)
    self.__index = self
    if cache then cache:add_item(uri, _uri) end
    return _uri
end

--- Converts URI to string representation
--- @param style string|nil 'local' (path only), 'remote' (full URI), or 'auth' (connection string)
function URI:to_string(style)
    style = style or 'local'
    if style == 'remote' then
        return self.uri
    end
    if style == 'local' then
        local _path = table.concat(self.path, '/')
        if _path:sub(1, 1) ~= '/' then _path = '/' .. _path end
        return _path
    end
    logger.warn(string.format("Invalid URI to_string style %s", style))
    return ''
end

--- Returns the parent URI
function URI:parent()
    local _path = {}
    for _, _item in ipairs(self.path) do
        table.insert(_path, _item)
    end
    table.remove(_path, #_path)
    if #_path == 0 then _path = { '/' } end

    return URI:new(string.format("%s://%s:%s/%s",
        self.protocol, self.host, self.port,
        table.concat(_path, '/') .. '/'
    ))
end

--- Returns the various hosts that are currently available (from saved config)
--- @param config Configuration
--- The Netman provided (provider managed) configuration
--- @return table
function M.ui.get_hosts(config)
    local hosts_as_dict = config:get('hosts') or {}
    local hosts = {}
    for host, _ in pairs(hosts_as_dict) do
        table.insert(hosts, host)
    end
    return hosts
end

--- Returns details for a host
--- @param config Configuration
--- @param host string
--- @param provider_cache Cache
--- @return table
function M.ui.get_host_details(config, host, provider_cache)
    local hosts = config:get('hosts') or {}
    local host_uri = hosts[host] or host
    local connection = WebDAV:new(host_uri, provider_cache)
    local get_path = function()
        return { { uri = string.format("%s://%s:%s/", connection.protocol, connection.host, connection.port), name = '/' } }
    end
    return {
        NAME = host,
        URI = string.format("%s://%s:%s/", connection.protocol, connection.host, connection.port),
        ENTRYPOINT = get_path
    }
end

function M.internal.prepare_config(config)
    logger.trace("Ensuring Provided WebDAV configuration has valid keys in it")
    if not config:get('hosts') then
        config:set('hosts', {})
        config:save()
    end
end

--- Parses ~/.netrc for machine entries and populates the WebDAV host config.
--- Follows the same pattern as SSH's parse_user_sshconfig.
--- @param config Configuration
function M.internal.parse_netrc(config)
    local netrc_path = string.format("%s/.netrc", vim.loop.os_homedir())
    local fh = io.open(netrc_path, 'r')
    if not fh then
        logger.info(string.format("No .netrc found at %s, skipping", netrc_path))
        return
    end
    logger.infof("Parsing .netrc from %s", netrc_path)

    local hosts = config:get('hosts')
    local current_machine = nil
    local current_login = nil
    local current_password = nil
    local count = 0

    local function flush_machine()
        if current_machine and current_login then
            local uri = string.format("davs://%s:%s@%s/", current_login, current_password or '', current_machine)
            hosts[current_machine] = uri
            count = count + 1
            logger.trace(string.format("Added host from .netrc: %s -> %s", current_machine, uri))
        end
        current_machine = nil
        current_login = nil
        current_password = nil
    end

    for raw_line in fh:lines() do
        local line = raw_line:gsub('#.*$', '')
        line = line:match('^%s*(.-)%s*$') or ''
        if line:len() == 0 then
            flush_machine()
            goto continue
        end

        local tokens = {}
        for token in line:gmatch('%S+') do
            table.insert(tokens, token)
        end

        local i = 1
        while i <= #tokens do
            local token = tokens[i]:lower()
            if token == 'machine' then
                flush_machine()
                current_machine = tokens[i + 1]
                i = i + 2
            elseif token == 'login' then
                current_login = tokens[i + 1]
                i = i + 2
            elseif token == 'password' then
                current_password = tokens[i + 1]
                i = i + 2
            elseif token == 'default' then
                -- WebDAV needs an explicit hostname, so default entries are skipped
                i = i + 1
            else
                i = i + 1
            end
        end
        ::continue::
    end
    fh:close()
    flush_machine()

    config:save()
    logger.info(string.format("Parsed .netrc: found %d WebDAV host(s)", count))
end

function M.internal.validate(uri, cache)
    assert(cache, string.format("No cache provided for read of %s", uri))
    uri = M.internal.URI:new(uri, cache)

    local connection = M.internal.WebDAV:new(uri, cache)
    return { uri = uri, connection = connection }
end

function M.internal.read_directory(uri, connection)
    logger.tracef("Reading %s as directory", uri:to_string('remote'))

    local children = connection:find(uri, { max_depth = 1 })
    if children.error then
        if children.error:match('[pP]ermission%s+[dD]enied') or children.error:match('403') or children.error:match('401') then
            return {
                success = false,
                message = {
                    message = string.format("Permission Denied when accessing %s", uri:to_string()),
                    error = api_flags.ERRORS.PERMISSION_ERROR
                }
            }
        end
        return {
            success = false,
            message = children.error
        }
    end

    local data = {}
    for _, child in ipairs(children) do
        local absolute_path = {}
        for _, part in ipairs(child.ABSOLUTE_PATH or {}) do
            table.insert(absolute_path, part)
        end
        data[child.URI or child.NAME] = {
            URI = child.URI or child.NAME,
            FIELD_TYPE = child.FIELD_TYPE,
            NAME = child.NAME,
            ABSOLUTE_PATH = child.ABSOLUTE_PATH or {},
            METADATA = child
        }
    end

    return {
        success = true,
        data = data,
        type = api_flags.READ_TYPE.EXPLORE
    }
end

function M.internal.read_file(uri, connection)
    logger.tracef("Reading %s as file", uri:to_string('remote'))
    local status = connection:get(uri, local_files, { new_file_name = uri.unique_name })
    local obj = nil
    if status.success then
        obj = {
            success = true,
            data = {
                local_path = string.format("%s%s", local_files, uri.unique_name),
                origin_path = uri:to_string()
            },
            type = api_flags.READ_TYPE.FILE
        }
    end
    if status.error then
        local handled = false
        if status.error:match('[pP]ermission%s+[dD]enied') or status.error:match('403') or status.error:match('401') then
            handled = true
            obj = {
                success = false,
                message = {
                    message = "Permission Denied",
                    error = api_flags.ERRORS.PERMISSION_ERROR
                }
            }
        end
        if not handled then
            logger.warn("Received unhandled error", status.error)
        end
    end
    if obj then status = obj end
    return status
end

--- Public API
--------------------------------------

function M.connect_host(uri, cache)
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    -- Verify connection by doing a lightweight PROPFIND on /
    local response = validation.connection:request('PROPFIND', '/', { depth = '0' })
    if response.exit_code ~= 0 then
        return {
            success = false,
            message = {
                message = string.format("Unable to connect to %s", validation.connection.base_url),
                error = response.stderr or 'Connection failed'
            }
        }
    end
    return { success = true }
end

function M.close_connection(uri, cache)
    -- HTTP connections are stateless; nothing to close
end

--- Reads contents from a WebDAV server
--- @param uri string The URI to read
--- @param cache Cache The netman.api provided cache
--- @return table @see :help netman.api.read for details
function M.read(uri, cache)
    local connection = nil
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    uri = validation.uri
    connection = validation.connection

    -- Stat the URI to determine type
    local stat = connection:stat(uri:to_string())
    local _, stat_data = next(stat)
    if not stat_data then
        return {
            success = false,
            message = {
                message = string.format("%s doesn't exist", uri:to_string()),
                error = api_flags.ERRORS.ITEM_DOESNT_EXIST
            }
        }
    end

    if stat_data.TYPE == 'directory' then
        return M.internal.read_directory(uri, connection)
    else
        return M.internal.read_file(uri, connection)
    end
end

--- Writes data to a URI via PUT
--- @param uri string The URI to write to
--- @param cache Cache The netman.api provided cache
--- @param data table The data to write (table of strings)
--- @return table
function M.write(uri, cache, data)
    local connection = nil
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    uri = validation.uri
    connection = validation.connection

    -- Write data to a local temp file first, then PUT it
    data = data or {}
    data = table.concat(data, '')
    local local_file = string.format("%s%s", local_files, uri.unique_name)
    local fh = io.open(local_file, 'w+')
    if not fh then
        return { success = false, message = { message = string.format("Unable to open local file %s", local_file) } }
    end
    fh:write(data)
    fh:flush()
    fh:close()

    local result = connection:put(local_file, uri)
    -- Clean up temp file
    pcall(vim.loop.fs_unlink, local_file)
    return result
end

--- Deletes a resource via DELETE
--- @param uri string The URI to delete
--- @param cache Cache The netman.api provided cache
--- @return table
function M.delete(uri, cache)
    local connection = nil
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    uri = validation.uri
    connection = validation.connection

    return connection:rm(uri, { force = true })
end

--- Gets metadata via PROPFIND
--- @param uri string The URI to stat
--- @param cache Cache The netman.api provided cache
--- @return table
function M.get_metadata(uri, cache)
    local connection = nil
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    uri = validation.uri
    connection = validation.connection

    return connection:stat(uri:to_string())
end

function M.copy(uris, target_uri, cache)
    local connection = nil
    local validation = M.internal.validate(target_uri, cache)
    if validation.message then return validation end
    connection = validation.connection
    target_uri = validation.uri

    if type(uris) ~= 'table' then uris = { uris } end
    local validated_uris = {}
    for _, uri in ipairs(uris) do
        local __ = M.internal.validate(uri, cache)
        if __.message then return __ end
        table.insert(validated_uris, __.uri)
    end

    return connection:cp(validated_uris, target_uri)
end

function M.move(uris, target_uri, cache)
    local connection = nil
    local validation = M.internal.validate(target_uri, cache)
    if validation.message then return validation end
    connection = validation.connection
    target_uri = validation.uri

    if type(uris) ~= 'table' then uris = { uris } end
    local validated_uris = {}
    for _, uri in ipairs(uris) do
        local __ = M.internal.validate(uri, cache)
        if __.message then return __ end
        table.insert(validated_uris, __.uri)
    end

    return connection:mv(validated_uris, target_uri)
end

function M.search(uri, cache, param, opts)
    -- WebDAV search is not widely supported; return nil for now
    return nil
end

--- Removes netrw's BufReadCmd autocmds for dav://* and davs://* patterns
--- so they don't interfere with netman's handler.
local function remove_netrw_autocmds()
    -- Netrw registers autocmds for dav://* and davs://* in the "Network"
    -- group (BufReadCmd, BufWriteCmd, FileReadCmd, FileWriteCmd, SourceCmd).
    -- These lack an `id` field so nvim_del_autocmd can't target them.
    pcall(vim.api.nvim_command, 'au! Network * dav://*')
    pcall(vim.api.nvim_command, 'au! Network * davs://*')
end

function M.init(config, provider_cache)
    remove_netrw_autocmds()
    -- Check if curl is available (vim.fn.executable returns 1 if found, 0 if not)
    if utils.os_has('curl') == 0 then
        local _error = "curl is not available on this system. WebDAV provider requires curl"
        logger.warn(_error)
        return false
    end

    -- Verify curl actually works
    local check_curl = { "curl", "--version" }
    local cmd_opts = { [command_flags.STDOUT_JOIN] = '', [command_flags.STDERR_JOIN] = '' }
    local result = shell:new(check_curl, cmd_opts):run()
    if result.exit_code ~= 0 then
        logger.warn("curl is installed but returned a non-zero exit code. WebDAV provider may not work correctly")
    end

    M.internal.prepare_config(config)
    M.internal.parse_netrc(config)

    logger.info("WebDAV provider initialized successfully")
    return true
end

return M
