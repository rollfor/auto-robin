package.path = "./?.lua;" .. package.path .. ";../../deps/rollfor/RollFor/src/?.lua;../../deps/rollfor/RollFor/src/libs/?.lua;../src/?.lua;../../?.lua;../../deps/rollfor/?.lua"

-- What this addon is, from RollFor's side: a registration, two loot handlers, a dropped-item
-- predicate and four settings. The other suites prove the rotation is right; this one proves
-- it gets installed in the right place, which is the part that has nothing to do with round
-- robin and everything to do with the extension API holding up.

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
require( "src/DropTable" )
require( "src/Tree" )
require( "src/SelectionTree" )
require( "src/SelectionTreeFrameContentTransformer" )
require( "src/SelectionTreeFrame" )
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
      round_robin_queue_rows = function() return 10 end
    },
    chat = require( "test/common/mocks/Chat" ).new( require( "mocks/ChatApi" ).new(), "RAID" ),
    player_info = require( "test/common/mocks/PlayerInfo" ).new( "Psikutas", "Warrior", true, true ),
    group_roster = { get_all_players_in_my_group = function() return {} end,
      am_i_in_group = function() return false end, find_player = function() return nil end,
      subscribe = function() end },
    popup_builder = function() return require( "mocks/PopupBuilder" ).new() end,
    -- Core's, and handed over rather than reached for: the window is built off ctx (API 5).
    -- Wrapped so a spec can read the config the window was actually built with.
    selection_tree = RollFor.SelectionTree,
    selection_tree_frame = {
      new = function( frame_config )
        registered.selection_tree_frame_config = frame_config
        return RollFor.SelectionTreeFrame.new( frame_config )
      end
    },
    get = function( name )
      if name == "loot_list" then return { get_items = function() return {} end } end
      if name == "master_loot_candidates" then return { get = function() return {} end } end
      if name == "auto_loot" then return { is_auto_looted = function() return false end } end
      if name == "loot_award_callback" then return function() end end
      if name == "confirmation_dialog" then return { show = function() end } end
    end,
    on_rf_command = function( name, callback ) registered.rf_commands[ name ] = callback end
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

-- award_policy arrived with API version 6, and asking for a version the host does not have is
-- what marks an extension incompatible.
function RegistrationSpec:should_declare_the_api_version_the_seams_it_uses_arrived_in()
  Extensions.clear()
  auto_robin.register()

  eq( Extensions.all()[ 1 ].incompatible, nil )
  eq( Extensions.all()[ 1 ].api_version, 6 )
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

SelectionWindowSpec = {}

-- Ticking a category row flips the flag is_category_active reads, so a display addon watching
-- RollForApi.round_robin.is_active goes stale until something says otherwise. on_changed is how
-- the window says so -- the same redraw the queue moving and the feature being switched off both
-- get. It has to be a function: the window calls it.
function SelectionWindowSpec:should_give_the_window_something_callable_to_report_a_tick_to()
  local registered = { rf_commands = {} }

  auto_robin.on_ready( ready_context( registered ) )

  eq( type( registered.selection_tree_frame_config.on_changed ), "function" )
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
  local registered = { rf_commands = {} }

  auto_robin.on_ready( ready_context( registered ) )

  eq( type( registered.rf_commands[ "autorobin" ] ), "function" )
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

-- Core's, not this addon's: the item selection window is core's window over this addon's
-- catalogue, so it draws core's tree rows. Named here so that core dropping one is a failure
-- with this addon's name on it rather than a crash in the game.
function WidgetSpec:should_find_the_core_row_types_its_windows_borrow()
  for _, line_type in ipairs( { "tree_node", "dropdown", "text", "button" } ) do
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

  eq( registered.numbers.round_robin_queue_rows, { default = 10, min = 5, max = 20 } )
end

os.exit( lu.LuaUnit.run() )
