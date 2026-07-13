local highlights = require("neo-tree.ui.highlights")
local common = require("neo-tree.sources.common.components")
local netman = require("netman.ui.neo-tree")
local netman_host_states = require("netman.tools.options").ui.STATES
local log = require("netman.tools.utils").log
local icon_map = function(item) return '' end
local success, web_devicons = pcall(require, "nvim-web-devicons")
if success then
    icon_map = web_devicons.get_icon
end

local M = {
    internal = {
        refresh_icon = " ",
        marked_icon = '♦ ',
    }
}

M.internal.state_map = {
    [netman_host_states.UNKNOWN] = {text=" ", highlight=""},
    [netman_host_states.AVAILABLE] = {text=" ", highlight="NeoTreeGitAdded"},
    [netman_host_states.STOPPED] = {text=" ", highlight="NeoTreeGitDeleted"},
    [netman_host_states.ERROR] = {text="❗", highlight="NeoTreeGitDeleted"},
    [netman_host_states.REFRESHING] = {text=M.internal.refresh_icon, highlight=""}
}

M.action = function(config, node, state)
    local _icon = { text = '', highlight = '' }
    local entry = node.extra
    if not entry then return end
    _icon.text = node.extra.action or ''
    return _icon
end

M.marked = function(config, node, state)
    local _icon = { text = '', highlight = '' }
    local entry = node.extra
    if not entry or not (entry.markable and entry.marked) then
        return
    end
    _icon.text = M.internal.marked_icon
    return _icon
end

M.expanded = function(config, node, state)
    -- Show expander only for nodes that can hold children.
    -- For providers, only show if they have actual hosts configured.
    if node.type == 'netman_provider' then
        if not (node.extra and node.extra.has_hosts) then
            return { text = '', highlight = 'NeoTreeExpander', no_padding = true }
        end
    elseif not (node:has_children() or node.type == 'directory' or node.type == 'netman_host') then
        return nil
    end
    if node:is_expanded() then
        return { text = '', highlight = 'NeoTreeExpander', no_padding = true }
    end
    return { text = '', highlight = 'NeoTreeExpander', no_padding = true }
end

M.icon = function(config, node, state)
    local _icon = { text = config.default or '*', highlight = config.highlight or 'NeoTreeFileIcon' }
    if node.name and type(node.name) == 'string' then
        local ok, result = pcall(common.icon, config, node, state)
        if ok and result and result.text and result.text ~= '' then
            _icon = result
        end
    end
    local entry = node.extra
    if not entry then
        return _icon
    end
    if entry.refresh then
        _icon.text = M.internal.refresh_icon
    elseif entry.error then
        _icon.text = M.internal.state_map.ERROR.text
    elseif entry.icon then
        _icon.text = string.format("%s ", entry.icon)
    elseif node.type == 'netman_host' then
        if entry.os and type(entry.os) == 'string' then
            local os_icon, os_hl = icon_map(entry.os)
            if os_icon and os_icon ~= '' then
                _icon.text, _icon.highlight = os_icon, os_hl
            end
        end
    end
    _icon.highlight = entry.highlight or _icon.highlight
    return _icon
end

M.git_status = function(config, node, state)
    if not node.path or type(node.path) ~= "string" or (node.id and node.id:match("^%w+://")) then
        return {}
    end
    return common.git_status(config, node, state)
end

M.state = function(config, node, state)
    local icon = ""
    local highlight = nil
    local entry = node.extra
    if not entry then
        return {
            text = icon,
            highlight = highlight
        }
    end
    local _state = M.internal.state_map[entry.state]
    if _state then
        icon = _state.text
        highlight = _state.highlight
    end
    return {
        text = icon,
        highlight = highlight
    }
end

return vim.tbl_deep_extend("force", common, M)
