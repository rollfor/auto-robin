-- A queue on the queue tabs of this addon's options page: what it lays out, what its search lists,
-- and what its controls do to it. It used to be a window of its own; where the page puts the lines
-- and the search box is OptionsPage_test's business.
--
-- The round-robin module is built here from stubs that implement exactly the methods it calls,
-- which is itself a statement of what it depends on -- filling them out to whole interfaces would
-- bury that. The specs also hang their own helpers off the tab.
---@diagnostic disable: missing-fields, inject-field
package.path = "./?.lua;" .. package.path .. ";../../deps/rollfor/RollFor/src/?.lua;../../deps/rollfor/RollFor/src/libs/?.lua;../src/?.lua;../../?.lua;../../deps/rollfor/?.lua"

require( "src/compat" )
local u = require( "RollForAutoRobin/test/utils" )
local lu, eq = u.luaunit( "assertEquals" )
u.multi_require_src( "DebugBuffer", "Module", "Types" )
require( "src/modules" )

-- Before the catalogues are required: they read the client's quality colours at load time,
-- which in the real client are set during UIParent load, well before any addon file runs.
u.mock_wow_api()
local Db = require( "src/Db" )
require( "src/AutoRoundRobinDb" )
local AutoRoundRobin = require( "src/AutoRoundRobin" )
local Transformer = require( "src/AutoRoundRobinQueuesContentTransformer" )
local QueuesTab = require( "src/AutoRoundRobinQueuesTab" )

local empty_notice = { type = "text", value = "Nobody in this queue yet.", padding = 10 }
local no_match_notice = { type = "text", value = "Nobody matches.", padding = 10 }

-- No Reset: it throws away every queue at once, so it lives on /rf autorobin reset instead of one
-- click away from the up arrow.
local buttons = {
  { type = "button", label = "Add", width = 60 },
  { type = "button", label = "Up", width = 60 },
  { type = "button", label = "Down", width = 60 }
}

-- Transient unless the spec says otherwise: these queues are seeded from the group, and the
-- roster only ever brings people in transient.
---@param name string
---@param opts table? -- { first = boolean, last = boolean, core = boolean, found = boolean }
local function line( name, opts )
  local o = opts or {}

  -- A row a search found can't move either way: the rows around it aren't its neighbours.
  return {
    type = "round_robin_row",
    player = RollFor.colorize_player_by_class( name, "Warrior" ),
    core = o.core or false,
    can_move_up = not o.found and not o.first,
    can_move_down = not o.found and not o.last
  }
end

-- How many are in the queue, aligned with the list's right edge. Its own line type rather than a
-- header row, so the viewport does not scroll it away with the first player.
---@param count number
local function total( count )
  return { type = "round_robin_count", count = tostring( count ), padding = 2 }
end

-- The whole queue in the order the transformer emits it: either the empty notice or the count and
-- one line per player, then the buttons. No column title above the names -- the queue is ordered,
-- so a header reading "Player" would say nothing the list did not.
---@param rows table[]?
---@param searching boolean?
local function queue( rows, searching )
  local content = {}

  if not rows or #rows == 0 then
    table.insert( content, searching and no_match_notice or empty_notice )
  else
    table.insert( content, total( #rows ) )

    -- Every row padded the same, so that scrolling the first one away does not take a wider gap
    -- with it and shift the rest of the list up.
    for _, row in ipairs( rows ) do
      row.padding = 2
      table.insert( content, row )
    end
  end

  for _, button in ipairs( buttons ) do table.insert( content, button ) end

  return unpack( content )
end

local function strip_functions( t )
  for _, entry in ipairs( t ) do
    for k, v in pairs( entry ) do
      if type( v ) == "function" then entry[ k ] = nil end
    end
  end

  return t
end

---@param names string[]
local function new_tab( names )
  local db = Db.new( {} )
  local round_robin_db = db( "autorobin" )
  RollForAutoRobin.AutoRoundRobinDb.ensure_seeded( round_robin_db )

  local players = {}
  for _, name in ipairs( names or {} ) do table.insert( players, { name = name, class = "Warrior" } ) end

  local in_group = true

  -- This tab never asks the client anything: the queue is the queue whether or not a corpse
  -- is open. The loot list stubs that used to stand here went with the award pass -- core walks
  -- the slots now and the rotation is handed one at a time.
  local candidates = {
    get = function() return players end,
    get_index = function() return 1 end
  }

  local round_robin = AutoRoundRobin.new(
    function() return RollFor.api end,
    round_robin_db,
    { auto_round_robin = function() return true end },
    { announce = function() end },
    -- In a group by default, so the queue hides anybody who isn't in it (see
    -- AutoRoundRobin.get_rows). Both are mutable so a spec can have somebody join or leave.
    { get_all_players_in_my_group = function() return players end, am_i_in_group = function() return in_group end },
    candidates,
    { on_loot_awarded = function() end }
  )

  round_robin.on_group_changed()

  local added_for
  -- The queue on screen and what is typed into its search box, which the page keeps.
  local category = "Marks"
  local search

  local tab = QueuesTab.new( round_robin, function( queue_category ) added_for = queue_category end )

  local transformer = Transformer.new()

  -- The model the transformer was last handed, which is where the controls are: the page draws
  -- them, and a click on one calls straight back into it.
  local model ---@type RoundRobinQueuesData

  ---@return table[]
  local function draw()
    model = tab.content( category, search )
    return transformer.transform( model )
  end

  tab.round_robin = round_robin
  tab.add_shown_for = function() return added_for end

  tab.lines = function() return strip_functions( draw() ) end

  tab.should_display = function( ... )
    eq( tab.lines(), { ... }, _, _, 2 )
  end

  ---@param button_type RoundRobinQueuesButtonType
  tab.click = function( button_type )
    draw()

    for _, button in ipairs( model.buttons ) do
      if button.type == button_type then button.callback() end
    end
  end

  tab.select_category = function( queue_category ) category = queue_category end

  ---@param text string?
  tab.search = function( text ) search = text end

  ---@param position number
  ---@param action "up"|"down"|"remove"
  tab.click_row = function( position, action )
    draw()

    local row = model.rows[ position ]
    if not row then error( string.format( "There is no row %s to click.", position ), 2 ) end

    row[ "on_" .. action ]()
  end

  -- The checkbox reports what it is asking for rather than toggling itself, so this does what the
  -- widget does: hands back the opposite of what the row was drawn showing.
  ---@param position number
  tab.toggle_core = function( position )
    draw()

    local row = model.rows[ position ]
    if not row then error( string.format( "There is no row %s to toggle.", position ), 2 ) end

    row.on_toggle_core( not row.core )
  end

  -- Somebody walks in. Not a roster sync -- that is on_group_changed -- just the group they are
  -- now part of, which is what decides whether the queue draws them.
  tab.join = function( name )
    table.insert( players, { name = name, class = "Warrior" } )
  end

  tab.leave_group = function()
    in_group = false
  end

  ---@param queue_category string?
  tab.queue_names = function( queue_category )
    local result = {}

    for _, player in ipairs( round_robin.get_queue( queue_category or "Marks" ) ) do
      table.insert( result, player.name )
    end

    return result
  end

  return tab
end

RoundRobinQueuesTabSpec = {}

function RoundRobinQueuesTabSpec:should_show_the_empty_notice_when_nobody_is_queued()
  local tab = new_tab( {} )

  tab.should_display( queue() )
end

function RoundRobinQueuesTabSpec:should_count_the_queue_above_the_list()
  local tab = new_tab( { "Ann", "Bob", "Cid" } )

  eq( tab.lines()[ 1 ], { type = "round_robin_count", count = "3", padding = 2 } )
end

function RoundRobinQueuesTabSpec:should_list_the_queue_in_order()
  local tab = new_tab( { "Ann", "Bob", "Cid" } )

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Bob" ),
    line( "Cid", { last = true } )
  } ) )
end

RoundRobinQueuesTabCategorySpec = {}

function RoundRobinQueuesTabCategorySpec:should_switch_to_another_categorys_queue()
  local tab = new_tab( { "Ann", "Bob" } )

  tab.select_category( "Gems" )

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Bob", { last = true } )
  } ) )
end

-- Editing one queue must not touch another: that is what makes them independent.
function RoundRobinQueuesTabCategorySpec:should_edit_only_the_category_on_screen()
  local tab = new_tab( { "Ann", "Bob" } )
  tab.select_category( "Gems" )

  tab.click( "CycleUp" )

  eq( tab.queue_names( "Gems" ), { "Bob", "Ann" } )
  eq( tab.queue_names( "Marks" ), { "Ann", "Bob" } )
end

RoundRobinQueuesTabEditingSpec = {}

function RoundRobinQueuesTabEditingSpec:should_move_a_player_up()
  local tab = new_tab( { "Ann", "Bob", "Cid" } )

  tab.click_row( 3, "up" )

  eq( tab.queue_names(), { "Ann", "Cid", "Bob" } )
  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Cid" ),
    line( "Bob", { last = true } )
  } ) )
end

function RoundRobinQueuesTabEditingSpec:should_move_a_player_down()
  local tab = new_tab( { "Ann", "Bob", "Cid" } )

  tab.click_row( 1, "down" )

  eq( tab.queue_names(), { "Bob", "Ann", "Cid" } )
end

function RoundRobinQueuesTabEditingSpec:should_remove_a_player()
  local tab = new_tab( { "Ann", "Bob" } )

  tab.click_row( 1, "remove" )

  eq( tab.queue_names(), { "Bob" } )
end

-- Up moves the list up: the head goes to the back and everybody else climbs a place.
function RoundRobinQueuesTabEditingSpec:should_cycle_the_whole_queue_up()
  local tab = new_tab( { "Ann", "Bob", "Cid" } )

  tab.click( "CycleUp" )

  eq( tab.queue_names(), { "Bob", "Cid", "Ann" } )
end

function RoundRobinQueuesTabEditingSpec:should_cycle_the_whole_queue_down()
  local tab = new_tab( { "Ann", "Bob", "Cid" } )

  tab.click( "CycleDown" )

  eq( tab.queue_names(), { "Cid", "Ann", "Bob" } )
end

function RoundRobinQueuesTabEditingSpec:should_open_the_add_popup_for_the_category_on_screen()
  local tab = new_tab( { "Ann" } )
  tab.select_category( "Hearts" )

  tab.click( "Add" )

  eq( tab.add_shown_for(), "Hearts" )
end

-- Read afresh on every draw: the page redraws whenever the queue says it moved, and what it draws
-- has to be the queue it moved to.
function RoundRobinQueuesTabEditingSpec:should_draw_the_queue_as_it_is_now()
  local tab = new_tab( { "Ann", "Bob" } )

  tab.round_robin.cycle( "Marks", 1 )

  tab.should_display( queue( {
    line( "Bob", { first = true } ),
    line( "Ann", { last = true } )
  } ) )
end

RoundRobinQueuesTabCoreSpec = {}

function RoundRobinQueuesTabCoreSpec:should_draw_a_player_added_by_hand_as_core()
  local tab = new_tab( { "Ann" } )

  tab.round_robin.add_player( "Marks", "Bob", "Warrior" )
  tab.join( "Bob" )

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Bob", { last = true, core = true } )
  } ) )
end

function RoundRobinQueuesTabCoreSpec:should_promote_the_player_whose_box_is_ticked()
  local tab = new_tab( { "Ann", "Bob" } )

  tab.toggle_core( 2 )

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Bob", { last = true, core = true } )
  } ) )
end

function RoundRobinQueuesTabCoreSpec:should_demote_the_player_whose_box_is_unticked()
  local tab = new_tab( { "Ann" } )

  tab.round_robin.add_player( "Marks", "Bob", "Warrior" )
  tab.join( "Bob" )
  tab.toggle_core( 2 )

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Bob", { last = true } )
  } ) )
end

-- The box says who survives the next group, not where they stand in this one.
function RoundRobinQueuesTabCoreSpec:should_leave_the_order_alone_when_a_box_is_ticked()
  local tab = new_tab( { "Ann", "Bob", "Cid" } )

  tab.toggle_core( 2 )

  eq( tab.queue_names(), { "Ann", "Bob", "Cid" } )
end

-- Each category owns its own queue, so a player is core in the one whose box was ticked and
-- nowhere else.
function RoundRobinQueuesTabCoreSpec:should_only_promote_in_the_category_on_screen()
  local tab = new_tab( { "Ann" } )

  tab.toggle_core( 1 )
  tab.select_category( "Gems" )

  tab.should_display( queue( { line( "Ann", { first = true, last = true } ) } ) )
end

RoundRobinQueuesTabAbsenceSpec = {}

-- Hidden, not dropped: they keep their place in the queue and take the next drop they are
-- around for.
function RoundRobinQueuesTabAbsenceSpec:should_hide_a_player_who_is_not_in_the_group()
  local tab = new_tab( { "Ann", "Cid" } )

  tab.round_robin.add_player( "Marks", "Bob", "Warrior" )

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Cid", { last = true } )
  } ) )
  eq( tab.queue_names(), { "Ann", "Cid", "Bob" } )
end

function RoundRobinQueuesTabAbsenceSpec:should_count_only_the_players_it_draws()
  local tab = new_tab( { "Ann" } )

  tab.round_robin.add_player( "Marks", "Bob", "Warrior" )

  eq( tab.lines()[ 1 ], { type = "round_robin_count", count = "1", padding = 2 } )
end

-- Out of a group there is nothing to be absent from, and it is the only time the core players
-- added between raids can all be seen at once.
function RoundRobinQueuesTabAbsenceSpec:should_show_everybody_when_not_in_a_group()
  local tab = new_tab( { "Ann" } )

  tab.round_robin.add_player( "Marks", "Bob", "Warrior" )
  tab.leave_group()

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Bob", { last = true, core = true } )
  } ) )
end

function RoundRobinQueuesTabAbsenceSpec:should_draw_a_hidden_player_again_once_they_join()
  local tab = new_tab( { "Ann" } )

  tab.round_robin.add_player( "Marks", "Bob", "Warrior" )
  tab.join( "Bob" )

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Bob", { last = true, core = true } )
  } ) )
end

-- The arrows move a player past the one above them on screen. Stepping one place in the queue
-- would swap them with the hidden player instead and redraw identically.
function RoundRobinQueuesTabAbsenceSpec:should_move_a_player_past_the_hidden_one_between_them()
  local tab = new_tab( { "Ann", "Cid" } )

  -- Ann, Bob (hidden), Cid
  tab.round_robin.add_player( "Marks", "Bob", "Warrior" )
  tab.round_robin.move_player( "Marks", 3, -1 )

  -- Cid is drawn second, so up means past Ann.
  tab.click_row( 2, "up" )

  eq( tab.queue_names(), { "Cid", "Bob", "Ann" } )
  tab.should_display( queue( {
    line( "Cid", { first = true } ),
    line( "Ann", { last = true } )
  } ) )
end

-- Up and Down rotate what is on screen, for the same reason the arrows move a player past their
-- neighbour on screen: rotating the whole queue would send an absent player to the back and
-- redraw identically, and a queue carried over from the last raid is normally full of them.
function RoundRobinQueuesTabAbsenceSpec:should_move_the_list_by_a_row_on_every_cycle_up()
  local tab = new_tab( { "Ann", "Cid" } )

  -- Ann, Bob (hidden), Cid
  tab.round_robin.add_player( "Marks", "Bob", "Warrior" )
  tab.round_robin.move_player( "Marks", 3, -1 )

  tab.click( "CycleUp" )

  eq( tab.queue_names(), { "Bob", "Cid", "Ann" } )
  tab.should_display( queue( {
    line( "Cid", { first = true } ),
    line( "Ann", { last = true } )
  } ) )

  tab.click( "CycleUp" )

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Cid", { last = true } )
  } ) )
end

function RoundRobinQueuesTabAbsenceSpec:should_move_the_list_by_a_row_on_every_cycle_down()
  local tab = new_tab( { "Ann", "Cid" } )

  tab.round_robin.add_player( "Marks", "Bob", "Warrior" )
  tab.round_robin.move_player( "Marks", 3, -1 )

  tab.click( "CycleDown" )

  eq( tab.queue_names(), { "Cid", "Ann", "Bob" } )
  tab.should_display( queue( {
    line( "Cid", { first = true } ),
    line( "Ann", { last = true } )
  } ) )

  tab.click( "CycleDown" )

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Cid", { last = true } )
  } ) )
end

-- The x takes out the player on that row, not whoever happens to sit at that index in the queue.
function RoundRobinQueuesTabAbsenceSpec:should_remove_the_player_on_the_row_not_the_queue_index()
  local tab = new_tab( { "Ann", "Cid" } )

  tab.round_robin.add_player( "Marks", "Bob", "Warrior" )
  tab.round_robin.move_player( "Marks", 3, -1 )

  tab.click_row( 2, "remove" )

  eq( tab.queue_names(), { "Ann", "Bob" } )
end

-- What is typed into a queue's search box. The page redraws on every change, so what a search
-- lists is simply what the queue lays out for that text.
RoundRobinQueuesTabSearchSpec = {}

function RoundRobinQueuesTabSearchSpec:should_list_only_players_whose_name_has_the_search_in_it()
  local tab = new_tab( { "Ann", "Bob", "Dana" } )

  tab.search( "an" )

  tab.should_display( queue( {
    line( "Ann", { found = true } ),
    line( "Dana", { found = true } )
  } ) )
end

-- Whose name starts with it comes before whose name only has it in the middle: the start of a
-- name is what somebody types when they are looking for one.
function RoundRobinQueuesTabSearchSpec:should_list_names_that_start_with_the_search_first()
  local tab = new_tab( { "Dana", "Anna", "Bran", "Andy" } )

  tab.search( "an" )

  tab.should_display( queue( {
    line( "Anna", { found = true } ),
    line( "Andy", { found = true } ),
    line( "Dana", { found = true } ),
    line( "Bran", { found = true } )
  } ) )
end

function RoundRobinQueuesTabSearchSpec:should_ignore_case()
  local tab = new_tab( { "Ann", "Bob" } )

  tab.search( "aNN" )

  tab.should_display( queue( { line( "Ann", { found = true } ) } ) )
end

-- An emptied box lists everybody again, in queue order, with the arrows back on.
function RoundRobinQueuesTabSearchSpec:should_list_everybody_once_the_search_is_removed()
  local tab = new_tab( { "Ann", "Bob" } )

  tab.search( "bo" )
  tab.search( "" )

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Bob", { last = true } )
  } ) )
end

function RoundRobinQueuesTabSearchSpec:should_treat_spaces_alone_as_no_search()
  local tab = new_tab( { "Ann", "Bob" } )

  tab.search( "   " )

  tab.should_display( queue( {
    line( "Ann", { first = true } ),
    line( "Bob", { last = true } )
  } ) )
end

-- A name has no spaces in it, so ones typed around the search are not part of it.
function RoundRobinQueuesTabSearchSpec:should_ignore_spaces_around_the_search()
  local tab = new_tab( { "Ann", "Bob" } )

  tab.search( " bo " )

  tab.should_display( queue( { line( "Bob", { found = true } ) } ) )
end

-- Letters, not a Lua pattern: a player typing a dot or a dash is searching for one.
function RoundRobinQueuesTabSearchSpec:should_search_for_the_text_as_typed()
  local tab = new_tab( { "Ann", "Bob" } )

  tab.search( "." )

  tab.should_display( queue( {}, true ) )
end

function RoundRobinQueuesTabSearchSpec:should_count_the_players_it_found()
  local tab = new_tab( { "Ann", "Bob", "Dana" } )

  tab.search( "an" )

  eq( tab.lines()[ 1 ], { type = "round_robin_count", count = "2", padding = 2 } )
end

function RoundRobinQueuesTabSearchSpec:should_say_when_nobody_matches()
  local tab = new_tab( { "Ann", "Bob" } )

  tab.search( "zed" )

  tab.should_display( queue( {}, true ) )
end

-- The x takes out the player the row was drawn for, wherever the search put them.
function RoundRobinQueuesTabSearchSpec:should_remove_the_player_on_the_row_it_found()
  local tab = new_tab( { "Dana", "Bob", "Anna" } )

  tab.search( "an" )
  tab.click_row( 1, "remove" )

  eq( tab.queue_names(), { "Dana", "Bob" } )
end

function RoundRobinQueuesTabSearchSpec:should_tick_the_player_on_the_row_it_found()
  local tab = new_tab( { "Dana", "Anna" } )

  tab.search( "an" )
  tab.toggle_core( 1 )
  tab.search( nil )

  tab.should_display( queue( {
    line( "Dana", { first = true } ),
    line( "Anna", { last = true, core = true } )
  } ) )
end

-- Out of order, the row above a player is not the one ahead of them in the queue, so the arrows
-- have nothing to move them past.
function RoundRobinQueuesTabSearchSpec:should_offer_no_arrows_while_searching()
  local tab = new_tab( { "Dana", "Anna" } )

  tab.search( "an" )

  local lines = tab.lines()
  eq( { lines[ 2 ].can_move_up, lines[ 2 ].can_move_down }, { false, false } )
  eq( { lines[ 3 ].can_move_up, lines[ 3 ].can_move_down }, { false, false } )
end

-- Up and Down still rotate the queue on screen -- the group, not what the search picked out.
function RoundRobinQueuesTabSearchSpec:should_cycle_the_whole_queue_while_searching()
  local tab = new_tab( { "Ann", "Bob", "Cid" } )

  tab.search( "cid" )
  tab.click( "CycleUp" )

  eq( tab.queue_names(), { "Bob", "Cid", "Ann" } )
end

os.exit( lu.LuaUnit.run() )
