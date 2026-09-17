RollForAutoRobin = RollForAutoRobin or {}
local ar = RollForAutoRobin

if ar.AutoRoundRobinQueuesContentTransformer then return end

-- Core's shared helpers. RollFor is guaranteed to be loaded: the TOC declares it as a
-- dependency, so the client refuses to load this addon without it.
local m = RollFor

local M = {}

-- What one queue on a queue tab of this addon's options page draws, as lines: the queue's length,
-- a row per player and the buttons under them. Each tab shows two queues side by side, and each
-- queue has a search box of its own above these lines (see OptionsPage). It used to be a window
-- with a category dropdown; the tabs say which queues these are now.

---@param label string
---@param width number
local function button_definition( label, width )
  return { type = "button", label = label, width = width }
end

M.button_definitions = {
  [ "Add" ] = button_definition( "Add", 60 ),
  [ "CycleUp" ] = button_definition( "Up", 60 ),
  [ "CycleDown" ] = button_definition( "Down", 60 )
}

---@alias RoundRobinQueuesButtonType
---| "Add"
---| "CycleUp"
---| "CycleDown"

---@class RoundRobinQueuesButtonWithCallback
---@field type RoundRobinQueuesButtonType
---@field callback fun()

---@class RoundRobinQueuesData
---@field rows RoundRobinQueuesRow[]
---@field buttons RoundRobinQueuesButtonWithCallback[]
---@field searching boolean -- rows are the players matching a search, not the queue in order

---@class RoundRobinQueuesRow : AutoRoundRobinRow
---@field on_up fun()?
---@field on_down fun()?
---@field on_remove fun()
---@field on_toggle_core fun( core: boolean )

---@class RoundRobinQueuesContentTransformer
---@field transform fun( data: RoundRobinQueuesData ): table

---@param content table
---@param buttons RoundRobinQueuesButtonWithCallback[]
local function add_buttons( content, buttons )
  for _, button in ipairs( buttons or {} ) do
    local definition = M.button_definitions[ button.type ]
    if not definition then error( string.format( "Unsupported button type: %s", button.type or "nil" ) ) end

    table.insert( content, {
      type = definition.type,
      label = definition.label,
      width = definition.width,
      on_click = button.callback
    } )
  end
end

-- Between rows, and above the first one. They add up to what the first row used to carry on its
-- own (see add_rows).
local row_gap = 2
local count_gap = 2

-- How many are listed: the queue, or the players a search matched. Above the list rather than in
-- the tab's label because it is a fact about the list, and it changes as you edit or search it.
---@param content table
---@param rows RoundRobinQueuesRow[]
local function add_count( content, rows )
  table.insert( content, {
    type = "round_robin_count",
    count = tostring( m.getn( rows ) ),
    -- The widget itself is a sliver that draws its number in the line above (see
    -- GuiElements.round_robin_count), so this padding is really the gap above the first row. It
    -- lives here rather than on that row because this line is never scrolled away, and a gap that
    -- belongs to a row disappears when that row does.
    padding = count_gap
  } )
end

-- A queue nobody is in yet, or a search nobody matches. The first is only reachable out of a group
-- with nothing added by hand, since joining seeds every queue.
---@param content table
---@param searching boolean
local function add_empty_notice( content, searching )
  local notice = searching and "Nobody matches." or "Nobody in this queue yet."
  table.insert( content, { type = "text", value = notice, padding = 10 } )
end

---@param row RoundRobinQueuesRow
---@return string
local function player_cell( row )
  return m.colorize_player_by_class( row.name, row.class )
end

-- Every row is padded the same. A wider gap on the first one would be a gap that exists only
-- while that row is on screen: padding is decided by a row's place in the whole list, not in the
-- viewport, so scrolling the first row away would take its extra space with it and the rest of
-- the list would ride up. Whatever the top of the list wants is the count line's to give.
--
-- A search lists players out of queue order, so the row above is not the one ahead in the queue
-- and an arrow would move somebody past a player the list isn't showing. Both arrows are off
-- until the search is cleared.
---@param content table
---@param rows RoundRobinQueuesRow[]
---@param searching boolean
local function add_rows( content, rows, searching )
  local count = m.getn( rows )

  for i, row in ipairs( rows ) do
    table.insert( content, {
      type = "round_robin_row",
      player = player_cell( row ),
      core = row.core,
      can_move_up = not searching and i > 1,
      can_move_down = not searching and i < count,
      on_up = row.on_up,
      on_down = row.on_down,
      on_remove = row.on_remove,
      on_toggle_core = row.on_toggle_core,
      padding = row_gap
    } )
  end
end

---@param data RoundRobinQueuesData
local function transform( data )
  local content = {}
  local rows = data.rows or {}
  local searching = data.searching and true or false

  if m.getn( rows ) == 0 then
    add_empty_notice( content, searching )
  else
    add_count( content, rows )
    add_rows( content, rows, searching )
  end

  add_buttons( content, data.buttons )

  return content
end

---@return RoundRobinQueuesContentTransformer
function M.new()
  return {
    transform = transform
  }
end

ar.AutoRoundRobinQueuesContentTransformer = M
return M
