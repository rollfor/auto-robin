package.path = "./?.lua;" .. package.path .. ";../../deps/rollfor/RollFor/src/?.lua;../../deps/rollfor/RollFor/src/libs/?.lua;../src/?.lua;../../?.lua;../../deps/rollfor/?.lua"

-- What this addon is, from RollFor's side: a registration, an award policy, a dropped-item
-- predicate, four settings, an options page and the /rf subcommand that opens it. The other
-- suites prove the rotation is right; this one proves it gets installed in the right place,
-- which is the part that has nothing to do with round robin and everything to do with the
-- extension API holding up.
---@diagnostic disable: missing-fields

require( "src/compat" )
local u = require( "RollForAutoRobin/test/utils" )
local lu, eq = u.luaunit( "assertEquals" )
require( "src/modules" )
u.multi_require_src( "DebugBuffer", "Module", "Types" )
require( "src/Ordering" )
local Extensions = require( "src/Extensions" )
-- on_ready builds the real windows, which are built on core's.
require( "src/GuiElements" )
require( "src/ListPopup" )
require( "src/ItemUtils" )

u.mock_wow_api()
u.load_extension()

local auto_robin = RollForAutoRobin.main

---@return table -- what on_enable was given, with everything it wrote to
local function enable_into()
  local registered = { toggles = {}, numbers = {}, predicates = {}, rf_commands = {},
    gui_elements = {}, policies = {} }

  auto_robin.on_enable( {
    config = {
      register_toggle = function( key, _, default ) registered.toggles[ key ] = default end,
      register_number = function( key, default, min, max )
        registered.numbers[ key ] = { default = default, min = min, max = max }
      end,
      auto_round_robin_announce_drops = function() return false end
    },
    gui_elements = registered.gui_elements,
    award_policy = function( spec ) table.insert( registered.policies, spec ) end,
    on_dropped_item = function( predicate ) table.insert( registered.predicates, predicate ) end,
    on_group_changed = function() end,
    on_rf_command = function( name, callback ) registered.rf_commands[ name ] = callback end
  } )

  return registered
end

-- Everything on_ready reaches for. It builds the real windows, so the stubs have to be
-- real enough to be built against -- but what is asserted is only what it registered.
---@param registered table
local function ready_context( registered )
  local Db = require( "src/Db" )
  local db = Db.new( {} )

  return {
    db = function( key ) return db( key ) end,
    api = function() return RollFor.api end,
    config = {
      subscribe = function() end,
      auto_round_robin = function() return true end,
      auto_round_robin_announce = function() return true end,
      auto_round_robin_announce_drops = function() return false end,
    },
    chat = require( "test/common/mocks/Chat" ).new( require( "mocks/ChatApi" ).new(), "RAID" ),
    player_info = require( "test/common/mocks/PlayerInfo" ).new( "Psikutas", "Warrior", true, true ),
    group_roster = { get_all_players_in_my_group = function() return {} end,
      am_i_in_group = function() return false end, find_player = function() return nil end,
      subscribe = function() end },
    popup_builder = function() return require( "mocks/PopupBuilder" ).new() end,
    get = function( name )
      if name == "loot_list" then return { get_items = function() return {} end } end
      if name == "master_loot_candidates" then return { get = function() return {} end } end
      if name == "auto_loot" then return { is_auto_looted = function() return false end } end
      if name == "loot_award_callback" then return function() end end
      if name == "confirmation_dialog" then return { show = function() end } end
    end,
    on_rf_command = function( name, callback ) registered.rf_commands[ name ] = callback end,
    open_options = function() table.insert( registered.opened, registered.page_tab or "no page" ) end
  }
end

RegistrationSpec = {}

function RegistrationSpec:should_register_itself_with_rollfor()
  Extensions.clear()
  eq( auto_robin.register(), true )

  local all = Extensions.all()
  eq( #all, 1 )
  eq( all[ 1 ].name, "auto_robin" )
  eq( all[ 1 ].title, "Auto Round Robin" )
end

-- Core draws a bare Enabled-switch page for an extension that supplies none of its own, so
-- offering one is what puts the summary and this addon's settings in the options window. No
-- Enabled switch on it, since core stops injecting that once we take the page.
function RegistrationSpec:should_offer_its_own_options_page()
  Extensions.clear()
  auto_robin.register()

  eq( type( Extensions.all()[ 1 ].options_page ), "function" )
end

-- "Auto round robin" is this addon's on/off switch, so core must not offer a second one above
-- it. The flag is also what keeps the extension enabled: with no switch anywhere, "off" would
-- be a state nothing could bring it back from.
function RegistrationSpec:should_ask_core_not_to_draw_an_enabled_switch()
  Extensions.clear()
  auto_robin.register()

  eq( Extensions.all()[ 1 ].hide_enabled_option, true )
  eq( Extensions.is_enabled( "auto_robin" ), true )
end

-- The selection tree arrived on ctx with API 5, award_policy with API 6, and open_options with
-- API 8. Asking for a version the host does not have is what marks an extension incompatible.
function RegistrationSpec:should_declare_the_api_version_the_seams_it_uses_arrived_in()
  Extensions.clear()
  auto_robin.register()

  eq( Extensions.all()[ 1 ].incompatible, nil )
  eq( Extensions.all()[ 1 ].api_version, 8 )
end

AwardPolicySpec = {}

-- The rotation registers no loot handler at all now. Handing items out is a policy: it says who
-- it wants a slot to go to and core performs the award, walks the slots, and decides -- from the
-- user's ordering -- which claimant outranks which. That is what `after = "auto_loot"` was
-- reaching for, by naming an addon that need not be installed to express a priority.
function AwardPolicySpec:should_register_itself_as_an_award_policy()
  local policies = enable_into().policies

  eq( table.getn( policies ), 1 )
  eq( policies[ 1 ].name, "auto_robin" )
  eq( type( policies[ 1 ].decide ), "function" )
  eq( type( policies[ 1 ].on_awarded ), "function" )
end

-- The title is what the user reads in core's priority list, so it says what the feature is
-- rather than repeating the id.
function AwardPolicySpec:should_give_the_priority_list_something_readable_to_show()
  eq( enable_into().policies[ 1 ].title, "Round robin" )
end

-- The rotation is built in on_ready and core asks at loot time, so arriving early is normal and
-- a policy that answers before there is a rotation must simply not want anything.
function AwardPolicySpec:should_have_no_opinion_before_the_rotation_is_built()
  local policy = enable_into().policies[ 1 ]
  local rotation = RollForAutoRobin.auto_round_robin
  RollForAutoRobin.auto_round_robin = nil

  eq( policy.decide( 1, { id = 123 } ), nil )

  RollForAutoRobin.auto_round_robin = rotation
end

SelectionChangedSpec = {}

-- Builds the page the way core does, keeping what it was handed rather than the page.
---@param ctx table
---@return AutoRobinOptionsPageDeps
local function page_deps( ctx )
  local new = RollForAutoRobin.OptionsPage.new
  local result

  RollForAutoRobin.OptionsPage.new = function( _, _, deps )
    result = deps
    return {}
  end

  Extensions.clear()
  auto_robin.register()
  Extensions.all()[ 1 ].options_page( ctx, u.modules().api.CreateFrame( "Frame" ) )

  RollForAutoRobin.OptionsPage.new = new

  return result
end

---@param ctx table
---@return fun()
local function page_on_changed( ctx )
  return page_deps( ctx ).on_selection_changed
end

-- Ticking a category row on the Loot tab flips the flag is_category_active reads, so a display
-- addon watching RollForApi.round_robin.is_active goes stale until something says otherwise. The
-- page's on_selection_changed is how it says so -- the same broadcast the queue moving and the feature
-- being switched off both get, for every category.
function SelectionChangedSpec:should_tell_display_addons_when_a_row_is_ticked()
  local registered = { rf_commands = {}, opened = {} }
  local ctx = ready_context( registered )
  local events = {}

  auto_robin.on_ready( ctx )

  RollFor.api.WeakAuras = {
    ScanEvents = function( event, category ) table.insert( events, event .. ":" .. category ) end
  }

  page_on_changed( ctx )()
  RollFor.api.WeakAuras = nil

  eq( events, {
    "ROLLFOR_ROUND_ROBIN_QUEUE_UPDATE:Marks",
    "ROLLFOR_ROUND_ROBIN_QUEUE_UPDATE:Hearts",
    "ROLLFOR_ROUND_ROBIN_QUEUE_UPDATE:Gems",
    "ROLLFOR_ROUND_ROBIN_QUEUE_UPDATE:Trash"
  } )
end

-- Core builds the page before on_ready builds the rotation, so a tick with no rotation yet has
-- nothing to announce and must not fail trying.
function SelectionChangedSpec:should_announce_nothing_before_the_rotation_is_built()
  local rotation = RollForAutoRobin.auto_round_robin
  local events = {}
  RollForAutoRobin.auto_round_robin = nil
  RollFor.api.WeakAuras = { ScanEvents = function( event ) table.insert( events, event ) end }

  page_on_changed( ready_context( { rf_commands = {}, opened = {} } ) )()

  RollFor.api.WeakAuras = nil
  RollForAutoRobin.auto_round_robin = rotation
  eq( events, {} )
end

DroppedItemSpec = {}

function DroppedItemSpec:should_register_exactly_one_predicate()
  eq( table.getn( enable_into().predicates ), 1 )
end

-- Nothing is set up here, so the rotation claims nothing and the predicate has no opinion.
-- What it answers when it does claim something is AutoRoundRobinSpec_test's business.
function DroppedItemSpec:should_have_no_opinion_before_the_rotation_is_built()
  RollForAutoRobin.auto_round_robin = nil

  local predicate = enable_into().predicates[ 1 ]

  eq( predicate( { id = 32897 } ), nil )
end

SlashCommandSpec = {}

-- A subcommand of core's /rf rather than a command of its own, so the windows open the way
-- every other RollFor window does. on_ready registers it, because the windows it opens do
-- not exist until then.
function SlashCommandSpec:should_own_the_rf_autorobin_subcommand()
  local registered = { rf_commands = {}, opened = {} }

  auto_robin.on_ready( ready_context( registered ) )

  eq( type( registered.rf_commands[ "autorobin" ] ), "function" )
end

-- The command on its own opens the settings. The tab is picked before the window opens, so the
-- page is drawn on it rather than on whichever tab was left open.
function SlashCommandSpec:should_open_the_options_page_on_the_general_tab()
  local registered = { rf_commands = {}, opened = {} }
  local page = RollForAutoRobin.options_page
  RollForAutoRobin.options_page = { select_tab = function( label ) registered.page_tab = label end }

  auto_robin.on_ready( ready_context( registered ) )
  registered.rf_commands[ "autorobin" ]( "" )
  registered.page_tab = nil
  registered.rf_commands[ "autorobin" ]( "   " )

  RollForAutoRobin.options_page = page
  eq( registered.opened, { "General", "General" } )
end

-- The page is core's to build, and a command typed before it exists still opens the window.
function SlashCommandSpec:should_still_open_the_options_without_a_page()
  local registered = { rf_commands = {}, opened = {} }
  local page = RollForAutoRobin.options_page
  RollForAutoRobin.options_page = nil

  auto_robin.on_ready( ready_context( registered ) )
  registered.rf_commands[ "autorobin" ]( "" )

  RollForAutoRobin.options_page = page
  eq( registered.opened, { "no page" } )
end

-- The text without its colour codes. The bars are left as the client is handed them: doubled,
-- since a single one starts an escape sequence. Doubled bars are set aside first, so the bar that
-- opens a code after one of them isn't taken for part of it.
---@param text string
---@return string
local function without_colours( text )
  local result = string.gsub( text, "||", "\1" )
  result = string.gsub( result, "|c%x%x%x%x%x%x%x%x", "" )
  result = string.gsub( result, "|r", "" )

  return (string.gsub( result, "\1", "||" ))
end

-- Runs /rf autorobin with each of the given arguments against a page that records which tab it
-- was told to open, and returns what the options window was opened on, and what was printed.
---@param ... string
---@return string[], string[]
local function autorobin( ... )
  local registered = { rf_commands = {}, opened = {} }
  local page, info = RollForAutoRobin.options_page, RollFor.info
  local printed = {}

  RollForAutoRobin.options_page = { select_tab = function( label ) registered.page_tab = label end }
  RollFor.info = function( message ) table.insert( printed, message ) end

  auto_robin.on_ready( ready_context( registered ) )

  for _, args in ipairs( { ... } ) do
    registered.page_tab = nil
    registered.rf_commands[ "autorobin" ]( args )
  end

  RollForAutoRobin.options_page, RollFor.info = page, info

  return registered.opened, printed
end

-- The list is on the Loot tab now, not in a window of its own.
function SlashCommandSpec:should_open_the_loot_tab_for_loot()
  eq( autorobin( "loot", "LOOT" ), { "Loot", "Loot" } )
end

-- A queue's name opens the tab that queue is on, whichever side of it the queue is.
function SlashCommandSpec:should_open_the_tab_each_queue_is_on()
  eq( autorobin( "hearts", "marks", "gems", "trash" ), { "Hearts/Marks", "Hearts/Marks", "Gems/Trash", "Gems/Trash" } )
end

-- Typed the way it is shown on the page or not.
function SlashCommandSpec:should_take_a_queues_name_in_any_case()
  eq( autorobin( "Gems", "TRASH" ), { "Gems/Trash", "Gems/Trash" } )
end

-- Nothing after the queue's name changes which tab it is on.
function SlashCommandSpec:should_ignore_whatever_follows_the_queues_name()
  eq( autorobin( "  marks please" ), { "Hearts/Marks" } )
end

-- `queue` is gone: the queues are opened by name now.
function SlashCommandSpec:should_not_open_anything_for_the_old_queue_argument()
  local opened, printed = autorobin( "queue" )

  eq( opened, {} )
  eq( #printed, 1 )
  eq( without_colours( printed[ 1 ] ), "Usage: /rf autorobin [loot||hearts||marks||gems||trash||reset]" )
end

-- The words are what to type, so they are highlighted, and what holds them together is not.
function SlashCommandSpec:should_write_the_brackets_and_bars_in_white()
  local white, hl = RollFor.colors.white, RollFor.colors.hl
  local _, printed = autorobin( "queue" )

  eq( printed[ 1 ], "Usage: " .. hl( "/rf autorobin" ) .. " " .. white( "[" ) .. hl( "loot" ) .. white( "||" )
    .. hl( "hearts" ) .. white( "||" ) .. hl( "marks" ) .. white( "||" ) .. hl( "gems" ) .. white( "||" )
    .. hl( "trash" ) .. white( "||" ) .. hl( "reset" ) .. white( "]" ) )
end

-- A typo says so rather than opening the list, which would look like the command worked.
function SlashCommandSpec:should_say_how_to_use_it_for_a_word_it_does_not_know()
  local opened, printed = autorobin( "heart" )

  eq( opened, {} )
  eq( #printed, 1 )
  eq( without_colours( printed[ 1 ] ), "Usage: /rf autorobin [loot||hearts||marks||gems||trash||reset]" )
end

QueuesTabSpec = {}

-- What the tab needs from on_ready, handed over as getters because the page is built first: the
-- rotation, and the form that adds somebody to a queue.
function QueuesTabSpec:should_hand_the_page_the_rotation_and_the_add_form()
  local registered = { rf_commands = {}, opened = {} }
  local ctx = ready_context( registered )
  auto_robin.on_ready( ctx )

  local deps = page_deps( ctx )
  local shown_for
  local add_player_frame = RollForAutoRobin.add_player_frame
  RollForAutoRobin.add_player_frame = { show = function( category ) shown_for = category end }

  deps.add_player( "Gems" )

  RollForAutoRobin.add_player_frame = add_player_frame
  eq( deps.round_robin(), RollForAutoRobin.auto_round_robin )
  eq( shown_for, "Gems" )
end

-- The form is handed the rotation it adds to and the roster it guesses a class from, in the order
-- it takes them. Swapped, Add asks the roster to add a player and fails in the game.
function QueuesTabSpec:should_give_the_add_form_the_rotation_to_add_to()
  local registered = { rf_commands = {}, opened = {} }
  local ctx = ready_context( registered )
  local new = RollForAutoRobin.AutoRoundRobinAddPlayerFrame.new
  local given

  RollForAutoRobin.AutoRoundRobinAddPlayerFrame.new = function( ... )
    given = { ... }
    return {}
  end

  auto_robin.on_ready( ctx )
  RollForAutoRobin.AutoRoundRobinAddPlayerFrame.new = new

  eq( given[ 2 ], RollForAutoRobin.auto_round_robin )
  eq( given[ 3 ], ctx.group_roster )
  eq( type( given[ 4 ] ), "function" )
end

-- Every award and every edit moves somebody, and the tab may be open while it happens.
function QueuesTabSpec:should_redraw_the_page_when_a_queue_moves()
  local registered = { rf_commands = {}, opened = {} }
  local page = RollForAutoRobin.options_page
  local refreshes = 0
  RollForAutoRobin.options_page = { refresh = function() refreshes = refreshes + 1 end }

  auto_robin.on_ready( ready_context( registered ) )
  RollForAutoRobin.auto_round_robin.add_player( "Marks", "Ann", "Warrior" )

  RollForAutoRobin.options_page = page
  eq( refreshes > 0, true )
end

-- What core hands back when it asks for the page is kept, so the command can reach it.
function SlashCommandSpec:should_keep_the_page_it_built()
  Extensions.clear()
  auto_robin.register()

  local canvas = u.modules().api.CreateFrame( "Frame" )
  local page = Extensions.all()[ 1 ].options_page( {}, canvas ) --[[@as AutoRobinOptionsPage]]

  eq( RollForAutoRobin.options_page, page )
  eq( type( page.select_tab ), "function" )
end

WidgetSpec = {}

-- The rows this addon's windows are made of. FrameBuilder resolves a row by looking its line
-- type up in the gui_elements table, so a window naming a type nobody registered gets nil and
-- crashes when it draws -- which no spec here would see, because they render through popup
-- doubles that fabricate a widget for any name asked of them.
--
-- These are the names the windows actually pass as row_type, header_type and line types.
function WidgetSpec:should_register_every_row_type_its_windows_name()
  local gui_elements = enable_into().gui_elements

  for _, line_type in ipairs( { "round_robin_row", "round_robin_count", "text_field" } ) do
    eq( type( gui_elements[ line_type ] ), "function", line_type )
  end
end

-- Core's, not this addon's: the options page draws core's tabs, settings and tree rows over this
-- addon's catalogue, and the queue windows borrow the rest. Named here so that core dropping one
-- is a failure with this addon's name on it rather than a crash in the game.
function WidgetSpec:should_find_the_core_row_types_its_windows_borrow()
  for _, line_type in ipairs( { "section_header", "paragraph", "tabs", "checkbox", "tree_node", "dropdown",
    "text", "button" } ) do
    eq( type( RollFor.GuiElements[ line_type ] ), "function", line_type )
  end
end

SettingsRegistrationSpec = {}

function SettingsRegistrationSpec:should_register_its_own_settings_rather_than_expecting_core_to_have_them()
  local registered = enable_into()

  eq( registered.toggles, {
    auto_round_robin = true,
    auto_round_robin_announce = true,
    -- Off: when the rotation hands an item out, the award announces it a moment later and
    -- the item was never up for grabs.
    auto_round_robin_announce_drops = false
  } )

  -- No row limit any more: it was the queue window's height, and the queue tabs show a whole raid.
  eq( registered.numbers, {} )
end

os.exit( lu.LuaUnit.run() )
