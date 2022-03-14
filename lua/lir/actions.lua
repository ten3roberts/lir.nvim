local history = require("lir.history")
local float = require("lir.float")
local utils = require("lir.utils")
local config = require("lir.config")
local lvim = require("lir.vim")
local Path = require("plenary.path")
local lir = require("lir")

local sep = Path.path.sep

local fn = vim.fn
local vim = vim
local uv = vim.loop
local a = vim.api

---@class lir_actions
local actions = {}

-----------------------------
-- Private
-----------------------------
local get_context = lvim.get_context

---@param cmd string
local function open(cmd)
  local ctx = get_context()
  if not ctx:current_value() then
    return
  end
  local filename = vim.fn.fnameescape(ctx.dir .. ctx:current_value())
  actions.quit()
  vim.cmd(cmd .. " " .. filename)
  history.add(ctx.dir, ctx:current_value())
end

---@param pathname string
---@return boolean
local function is_root(pathname)
  if sep == "\\" then
    return string.match(pathname, "^[A-Z]:\\?$")
  end
  return pathname == "/"
end

-----------------------------
-- Export
-----------------------------

--- edit
---@param opts table
function actions.edit(opts)
  opts = opts or {}
  local modified_split_command = vim.F.if_nil(opts.modified_split_command, "split")

  local ctx = get_context()
  local dir, file = ctx.dir, ctx:current_value()
  if not file then
    return
  end

  local keepalt = (vim.w.lir_is_float and "") or "keepalt"

  if vim.w.lir_is_float and not ctx:is_dir_current() then
    -- 閉じてから開く
    actions.quit()
  end

  local path = dir .. file
  -- Go directly and reuse lir buffer if directory is opened
  history.add(dir, file)
  if Path:new(path):is_dir() then
    return lir.init(path)
  end

  local cmd = (vim.api.nvim_buf_get_option(0, "modified") and modified_split_command) or "edit"

  vim.cmd(string.format("%s %s %s", keepalt, cmd, vim.fn.fnameescape(dir .. file)))
end

--- split
function actions.split()
  open("new")
end

--- vsplit
function actions.vsplit()
  open("vnew")
end

--- tabedit
function actions.tabedit()
  open("tabedit")
end

--- up
function actions.up()
  local cur_file, path, name, dir
  local ctx = get_context()
  cur_file = ctx:current_value()
  path = string.gsub(ctx.dir, sep .. "$", "")
  name = vim.fn.fnamemodify(path, ":t")
  if name == "" then
    return
  end

  dir = vim.fn.fnamemodify(path, ":p:h:h")

  history.add(path, cur_file)
  history.add(dir, name)

  -- vim.cmd("keepalt edit " .. dir)
  lir.init(dir, name)

  if is_root(dir) then
    vim.cmd("doautocmd BufEnter")
  end
end

--- quit
function actions.quit()
  if vim.w.lir_is_float then
    float.close()
  else
    if vim.w.lir_file_quit_on_edit ~= nil then
      vim.cmd("edit " .. vim.w.lir_file_quit_on_edit)
    end
  end
end

--- mkdir
function actions.mkdir()
  local ctx = get_context()
  vim.ui.input( {prompt="Create directory: "}, function(name)
  if not name or name == "" then
    return
  end

  if name == "." or name == ".." then
    utils.error("Invalid directory name: " .. name)
    return
  end

  local path = Path:new(ctx.dir .. name)
  if path:exists() then
    utils.error("Directory already exists")
    -- cursor jump
    local lnum = ctx:indexof(name)
    if lnum then
      vim.cmd(tostring(lnum))
    end
    return
  end

  path:mkdir({ parents = true })

  actions.reload()

  vim.schedule(function()
    local lnum = lvim.get_context():indexof(name)
    if lnum then
      vim.cmd(tostring(lnum))
    end
  end)
  end)
end

--- rename
function actions.rename(use_default)
  local ctx = get_context()
  local old = string.gsub(ctx:current_value(), sep .. "$", "")
  local default = ""
  if use_default ~= false then
    default = old
  end

  local opts = {
    completion = "dir",
    prompt = "Rename: ",
    default = default,
  }

  -- cd to the currently focused dir to get completion from the current directory
  local old_dir = fn.getcwd()

  vim.cmd("noau :cd " .. ctx.dir)

  vim.ui.input(opts, function(new)
    if new == nil or new == old then
      vim.cmd("noau :cd " .. old_dir)
      return
    end

    -- Restore working directory
    vim.cmd("noau :cd " .. old_dir)

    -- If target is a directory, move the file into the directory.
    -- Makes it work like linux `mv`
    local stat = uv.fs_stat(ctx.dir .. new)
    if stat and stat.type == "directory" then
      new = string.format("%s/%s", new, old)
    end
    print(new)

    if not uv.fs_rename(ctx.dir .. old, ctx.dir .. new) then
      utils.error("Rename failed")
    end

    actions.reload()
  end)
end

--- delete
function actions.delete(force)
  local ctx = get_context()
  local name = ctx:current_value()

  if not force and vim.fn.confirm("Delete?: " .. name, "&Yes\n&No", 1) ~= 1 then
    -- Esc は 0 を返す
    return
  end

  local path = Path:new(ctx.dir .. name)
  if path:is_dir() then
    path:rm({ recursive = true })
  else
    if not uv.fs_unlink(path:absolute()) then
      utils.error("Delete file failed")
      return
    end
  end

  actions.reload()
end

--- wipeout
function actions.wipeout()
  local ctx = get_context()
  if not ctx:is_dir_current() then
    local name = ctx:current().fullpath
    local bufnr = vim.fn.bufnr(name)
    if vim.fn.confirm("Delete?: " .. name, "&Yes\n&No", 1) ~= 1 then
      return
    end
    if bufnr ~= -1 then
      a.nvim_buf_delete(bufnr, { force = true })
    end
    actions.delete(true)
  else
    actions.delete()
  end
end

--- newfile
function actions.newfile()
  local ctx = get_context()
  vim.ui.input({ prompt="Filename: "}, function(input)
    if input and input ~= "" then
      if vim.w.lir_is_float then
        float.close()
        vim.cmd(":edit " .. ctx.dir .. input)
      else
        vim.cmd(":keepalt edit " .. ctx.dir .. input)
      end
    end
  end)
end

--- cd
function actions.cd()
  local ctx = get_context()
  vim.cmd(string.format([[silent execute (haslocaldir() ? 'lcd' : 'cd') '%s']], ctx.dir))
  print("cd: " .. ctx.dir)
end

--- reload
function actions.reload(_)
  lir.init(get_context().dir)
end

--- yank_path
function actions.yank_path()
  local ctx = get_context()
  local path = ctx.dir .. ctx:current_value()
  vim.fn.setreg(vim.v.register, path)
  print("Yank path: " .. path)
end

--- toggle_show_hidden
function actions.toggle_show_hidden()
  config.values.show_hidden_files = not config.values.show_hidden_files
  actions.reload()
end

return actions
