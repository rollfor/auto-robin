RollForAutoRobin = RollForAutoRobin or {}
local ar = RollForAutoRobin

if ar.AutoRoundRobinQueuesTab then return end

local M = {}

-- The round-robin queues as the queue tabs of this addon's options page show them: two queues a
-- tab, each with a search box. Wiring only: AutoRoundRobin owns the queues and every rule about
-- them, this file turns its rows into what AutoRoundRobinQueuesContentTransformer lays out and
-- hands the clicks back. The page draws the lines, and owns what was typed into each search box.
-- It used to be a window of its own, and /rf autorobin followed by a queue's name now opens the
-- tab that queue is on.

---@class AutoRoundRobinQueuesTab
---@field content fun( category: string, search: string? ): RoundRobinQueuesData

-- The players whose name has the search in it, ignoring case: those whose name starts with it
-- first, then those who only have it somewhere in the middle, each group in queue order. A search
-- of nothing but spaces is no search, and lists everybody in queue order.
---@param rows AutoRoundRobinRow[]
---@param search string?
---@return AutoRoundRobinRow[]
function M.search( rows, search )
  local needle = string.lower( string.match( search or "", "^%s*(.-)%s*$" ) )
  if needle == "" then return rows end

  local starting, containing = {}, {}

  for _, row in ipairs( rows ) do
    local at = string.find( string.lower( row.name ), needle, 1, true )

    if at == 1 then
      table.insert( starting, row )
    elseif at then
      table.insert( containing, row )
    end
  end

  for _, row in ipairs( containing ) do table.insert( starting, row ) end

  return starting
end

---@param search string?
---@return boolean
local function is_searching( search )
  return string.find( search or "", "%S" ) ~= nil
end

---@param round_robin AutoRoundRobin
---@param add_player fun( category: string ) -- opens the form that puts somebody into a queue
---@return AutoRoundRobinQueuesTab
function M.new( round_robin, add_player )
  -- Anybody not in the group is left out (see AutoRoundRobin.get_rows), so a row's place in this
  -- list is not its place in the queue. Every callback acts on the queue, so all of them are
  -- bound to `position` -- the index the queue knows it by -- and never to the drawn order.
  ---@param category string
  ---@param search string?
  ---@return RoundRobinQueuesRow[]
  local function rows( category, search )
    local visible = round_robin.get_rows( category )
    local searching = is_searching( search )
    local result = {}

    -- The arrows move a player past the one above or below them *on screen*. Stepping one place
    -- in the queue instead would swap them with a hidden player and redraw identically, which
    -- reads as a dead button. A search lists players out of order, so there is no neighbour to
    -- move past, and the arrows are off (see the transformer).
    ---@param i number
    ---@param offset number
    ---@return fun()
    local function swap_with_neighbour( i, offset )
      return function()
        local from, to = visible[ i ], visible[ i + offset ]
        if not to then return end

        round_robin.move_player( category, from.position, to.position - from.position )
      end
    end

    local listed = M.search( visible, search )

    for i, row in ipairs( listed ) do
      table.insert( result, {
        name = row.name,
        class = row.class,
        core = row.core,
        -- None of these redraw anything themselves: every one of them edits the queue, and the
        -- queue telling its subscribers is what redraws the page, so the next click is against
        -- the list it just produced.
        on_up = not searching and swap_with_neighbour( i, -1 ) or nil,
        on_down = not searching and swap_with_neighbour( i, 1 ) or nil,
        on_remove = function() round_robin.remove_player( category, row.position ) end,
        on_toggle_core = function( core ) round_robin.set_core( category, row.position, core ) end
      } )
    end

    return result
  end

  -- Read fresh on every draw, so a queue that moved, or somebody who joined the group, is on
  -- screen the next time the page is.
  ---@param category string
  ---@param search string? -- what is typed into the queue's search box
  ---@return RoundRobinQueuesData
  local function content( category, search )
    return {
      rows = rows( category, search ),
      searching = is_searching( search ),
      -- Resetting is /rf autorobin reset: it throws away every queue at once, which is not
      -- something to leave one click away from the up arrow.
      buttons = {
        { type = "Add", callback = function() add_player( category ) end },
        -- Up moves the list up: the head goes to the back and everybody else climbs a place. The
        -- players on screen, that is, not the ones a search picked out.
        { type = "CycleUp", callback = function() round_robin.cycle( category, 1 ) end },
        { type = "CycleDown", callback = function() round_robin.cycle( category, -1 ) end }
      }
    }
  end

  ---@type AutoRoundRobinQueuesTab
  return {
    content = content
  }
end

ar.AutoRoundRobinQueuesTab = M
return M
