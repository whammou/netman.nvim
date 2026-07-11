local config = {
    window = {}
}

config.renderers =
{
    file = {
        { 'indent'  },
        { 'marked'  },
        { 'icon'    },
        { 'name'    }
    },
    directory = {
        { 'indent'  },
        { 'marked'  },
        { 'icon'    },
        { 'expanded'},
        { 'name'    }
    },
    netman_provider = {
        { 'indent'  },
        { 'expanded'},
        { 'icon'    },
        { 'name'    }
    },
    netman_host = {
        { 'indent'  },
        { 'expanded'},
        { 'state'   },
        { 'icon'    },
        { 'name'    }
    },
    netman_bookmark = {
        { 'indent' },
        { 'icon'   },
        { 'name'   }
    },
    netman_stop    = {
        { 'indent' },
        { 'icon'   },
        { 'name'   },
        { 'action' }
    },
}

config.window.mappings = {
    ["<C-s>"] = "quick_jump",
    ["<Tab>"] = "select",
    ["<C-;>"] = "clear_selection",
    ["<space>"] = "toggle_node",
    ["<2-LeftMouse>"] = "open",
    ["<cr>"] = "open",
    ["<esc>"] = "cancel",
    ["P"] = "toggle_preview",
    ["<C-f>"] = { "scroll_preview", config = {direction = -10} },
    ["<C-b>"] = { "scroll_preview", config = {direction = 10} },
    ["l"] = "focus_preview",
    ["S"] = "open_split",
    ["s"] = "open_vsplit",
    ["t"] = "open_tabnew",
    ["w"] = "open_with_window_picker",
    ["C"] = "close_node",
    ["z"] = "close_all_nodes",
    ["R"] = "refresh",
    ["a"] = { "add", config = { show_path = "none" } },
    ["A"] = "add_directory",
    ["d"] = "delete",
    ["T"] = "trash",
    ["u"] = "undo",
    ["r"] = "rename",
    ["c"] = "copy",
    ["e"] = "toggle_auto_expand_width",
    ["q"] = "close_window",
    ["?"] = "show_help",
    ["<"] = "prev_source",
    [">"] = "next_source",
    -- Netman-specific: mark nodes for batch operations
    ['m'] = 'mark_node',
    ['x'] = 'move_node',
    ['p'] = 'paste_node',
    ['y'] = 'yank_node',
}

return config
