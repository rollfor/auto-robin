local u = require( "RollForAutoRobin/test/utils" )
local reqsrc = u.multi_require_src
local lu, eq = u.luaunit( "assertEquals" ) ---@diagnostic disable-line: unused-local
local m, T, IU = require( "src/modules" ), require( "src/Types" ), require( "src/ItemUtils" )
-- EXTENSION: this addon registers its row widgets into core's table during on_enable.
require( "src/GuiElements" )
reqsrc( "DebugBuffer", "Module", "Types", "RollingLogicUtils", "RollTracker" )
reqsrc( "TieRollingLogic", "SoftResRollingLogic", "NonSoftResRollingLogic", "RaidRollRollingLogic", "InstaRaidRollRollingLogic" )
require( "src/AwardedLoot" )
local SoftResSourceMock = require( "mocks/SoftResSource" )
local SoftResAwardedLootDecorator = require( "mocks/SoftResAwardedLootDecorator" )
require( "src/Ordering" )
local Chain = require( "src/Chain" )
require( "src/DropTable" )
require( "src/SoftRes" )
local Db = require( "src/Db" )
local RollingLogic = require( "src/RollingLogic" )
local sr, hr = u.soft_res_item, u.hard_res_item ---@diagnostic disable-line: unused-local
local c, r, pm = u.console_message, u.raid_message, u.party_message ---@diagnostic disable-line: unused-local
local cr, rw = u.console_and_raid_message, u.raid_warning ---@diagnostic disable-line: unused-local
local C, RT, RS = T.PlayerClass, T.RollType, T.RollingStrategy ---@diagnostic disable-line: unused-local
local make_player = T.make_player
local BindType = IU.BindType

u.mock_wow_api()

-- EXTENSION: this addon's modules, after mock_wow_api rather than before it --
-- AutoRoundRobinDb colours its categories from ITEM_QUALITY_COLORS at load time, which the
-- client has built by then and a test has not.
local auto_robin = (function()
  u.load_extension()
  return RollForAutoRobin.main
end)()

local M = {}

---@param name string
---@param class PlayerClass?
---@return Player
function M.p( name, class ) return make_player( name, class or C.Warrior, true ) end

M.mock_roster = require( "test/common/mocks/GroupRosterApi" ).new

local function enable_debug( ... ) ---@diagnostic disable-line: unused-local, unused-function
  local module_names = { ... }

  for _, module_name in ipairs( module_names ) do
    local module = m[ module_name ]
    if module and module.debug and module.debug.enable then
      u.info( string.format( "Enabling debug for %s.", module_name ) )
      module.debug.enable( true )
    end
  end
end

---@return ChatApiMock
function M.mock_chat()
  return require( "mocks/ChatApi" ).new() ---@diagnostic disable-next-line: return-type-mismatch
end

---@return Config
function M.mock_config( configuration )
  local config = configuration

  return {
    auto_raid_roll = function() return config and config.auto_raid_roll end,
    raid_roll_again = function() return config and config.raid_roll_again end,
    rolling_popup_lock = function() return config and config.rolling_popup_lock end,
    subscribe = function() end,
    rolling_popup = function() return true end,
    ms_roll_threshold = function() return 100 end,
    os_roll_threshold = function() return 99 end,
    default_rolling_time_seconds = function() return 8 end,
    master_loot_frame_rows = function() return 5 end,
    sr_roll_spacing = function()
      if config and config.sr_roll_spacing then return config.sr_roll_spacing end
      return 24
    end,
    roll_threshold = function()
      return {
        value = 100,
        str = "/roll"
      }
    end,
    classic_look = function() return false end,
    -- EXTENSION: this addon's own settings. In the real addon these arrive through
    -- ctx.config.register_toggle/register_number during on_enable; the stub declares them
    -- directly, the same way it declares core's.
    auto_round_robin = function()
      if config and config.auto_round_robin ~= nil then return config.auto_round_robin end
      return true
    end,
    auto_round_robin_announce = function()
      if config and config.auto_round_robin_announce ~= nil then return config.auto_round_robin_announce end
      return true
    end,
    auto_round_robin_announce_drops = function() return config and config.auto_round_robin_announce_drops end,
  }
end

---@param data table?
---@param extend fun( softres_chain: Chain, awarded_loot_chain: Chain )? -- stands in for Extensions.enable
---@return GroupAwareSoftRes
---@return AwardedLoot
-- EXTENSION: core no longer ships the soft-res backbone -- matched_name, awarded_loot and
-- present_players belong to the soft-res source extension, RollForSoftRes.
-- This addon touches none of them, but its specs still need soft-res *data* to arrive
-- (a soft-ressed item is left to the rollers rather than handed out by the rotation), so
-- the harness stands in for a source with identity links over the vendored dumb double.
local function group_aware_softres( group_roster, awarded_loot, data, extend )
  local awarded_loot_chain = Chain.new( "awarded_loot" )
  local softres_chain = Chain.new( "softres" )

  -- Resolved when the soft-res chain is built, which happens after the awarded-loot one.
  local decorated_awarded_loot

  softres_chain.add( { name = "matched_name", after = Chain.BASE, factory = function( inner ) return inner end } )

  softres_chain.add( {
    name = "awarded_loot",
    after = "matched_name",
    factory = function( inner ) return SoftResAwardedLootDecorator.new( decorated_awarded_loot, inner ) end
  } )

  softres_chain.add( { name = "present_players", after = "awarded_loot", factory = function( inner ) return inner end } )

  softres_chain.tap( { name = "unfiltered", before = "present_players" } )

  if extend then extend( softres_chain, awarded_loot_chain ) end

  decorated_awarded_loot = awarded_loot_chain.build( awarded_loot ).final

  local result = softres_chain.build( SoftResSourceMock.new( data, function( name )
    local player = group_roster.find_player( name )
    return player and player.class
  end ) ).final

  return result, decorated_awarded_loot
end

function M.mock_loot_facade()
  return require( "test/common/mocks/LootFacade" ).new()
end

---@param name string
---@param id number?
---@param sr_players RollingPlayer[]?
---@param hard_ressed boolean?
---@param quality number?
---@param bind_type BindType?
---@return MasterLootDistributableItem
function M.i( name, id, sr_players, hard_ressed, quality, bind_type )
  local l = u.item_link( name, id )
  local tooltip_link = IU.get_tooltip_link( l )
  local item = IU.make_dropped_item( id or 123, name, l, tooltip_link, quality or 4, nil, nil, bind_type or BindType.None )

  if hard_ressed then
    return IU.make_hardres_dropped_item( item )
  end

  if sr_players and #sr_players > 0 then
    return IU.make_softres_dropped_item( item, sr_players )
  end

  return item
end

-- The same seam for the round-robin GUI's list, which is a flat Category -> items tree rather
-- than auto-loot's nested one (see AutoRoundRobinDb). Test items aren't in the real catalogue, so
-- this writes what ticking a row would produce: the item enabled under an enabled category.
-- Everything goes under one category, because which queue serves an item is what the category
-- names, and a spec that wants two queues says so by naming them.
---@param db table the autorobin_db the AutoRoundRobin under test was built with
function M.round_robin_list( db )
  local DEFAULT = "Gems"

  ---@param category string?
  local function category_entry( category )
    local name = category or DEFAULT
    db.ids = db.ids or {}
    db.ids[ name ] = db.ids[ name ] or { enabled = true, order = 1, items = {} }
    db.ids[ name ].enabled = true

    return db.ids[ name ]
  end

  ---@param item DroppedItem
  ---@param category string?
  local function enable( item, category )
    category_entry( category ).items[ item.id ] = {
      enabled = true, name = item.name, quality = item.quality, icon = 0
    }
  end

  ---@param item DroppedItem
  ---@param category string?
  local function disable( item, category )
    local entry = category_entry( category ).items[ item.id ]
    if entry then entry.enabled = false end
  end

  ---@param enabled boolean
  ---@param category string?
  local function set_category_enabled( enabled, category )
    category_entry( category ).enabled = enabled
  end

  -- The fallback category's rows are qualities, not items, so ticking one is a different write --
  -- the same one SelectionTree.set_checked would make on a quality leaf. The category is seeded by
  -- AutoRoundRobinDb.ensure_seeded and starts off, so this switches on both it and the row.
  ---@param quality number
  local function enable_trash( quality )
    local trash = db.ids[ RollForAutoRobin.AutoRoundRobinDb.TRASH ]
    trash.enabled = true
    trash.qualities[ quality ].enabled = true
  end

  -- The ignore list. Unlike the two seams above this invents nothing: its rows are real catalogue
  -- ids that ensure_seeded has already put there, disabled, so all there is to do is tick them.
  ---@param item_id number
  local function ignore_trash( item_id )
    local ignored = db.ids[ RollForAutoRobin.AutoRoundRobinDb.TRASH_IGNORED ]
    ignored.enabled = true
    ignored.items[ item_id ].enabled = true
  end

  -- The whole catalogue ticked: every category, every item row and every quality row. What a spec
  -- means by "auto round robin fully armed" -- so that whatever it then proves the pass does not
  -- do, it isn't because something was left switched off.
  local function enable_everything()
    for _, category in pairs( db.ids ) do
      category.enabled = true

      for _, item in pairs( category.items or {} ) do item.enabled = true end
      for _, quality in pairs( category.qualities or {} ) do quality.enabled = true end
    end
  end

  return {
    enable = enable,
    disable = disable,
    set_category_enabled = set_category_enabled,
    enable_trash = enable_trash,
    ignore_trash = ignore_trash,
    enable_everything = enable_everything
  }
end

---@param id number?
---@param quality number?
---@param bind_type BindType?
---@return MasterLootDistributableItem
function M.qi( name, id, quality, bind_type )
  return M.i( name, id, nil, nil, quality, bind_type )
end

function M.new_roll_for()
  local dependencies = {}
  local builder = {}

  ---@param chat_api ChatApi|ChatApiMock
  function builder.chat( self, chat_api )
    dependencies[ "ChatApi" ] = chat_api
    return self
  end

  function builder.config( self, config )
    dependencies[ "Config" ] = M.mock_config( config )
    return self
  end

  ---@param loot_facade LootFacadeMock
  function builder.loot_facade( self, loot_facade )
    dependencies[ "LootFacade" ] = loot_facade
    return self
  end

  function builder.no_master_loot_candidates( self )
    dependencies[ "MasterLootCandidatesApi" ] = require( "test/common/mocks/MasterLootCandidatesApi" ).new()
    return self
  end

  ---@param ... Player[]
  function builder.roster( self, ... )
    dependencies[ "GroupRosterApi" ] = M.mock_roster( { ... } )
    return self
  end

  ---@param ... Player[]
  function builder.raid_roster( self, ... )
    dependencies[ "GroupRosterApi" ] = M.mock_roster( { ... }, true )
    return self
  end

  function builder.soft_res_data( self, ... )
    dependencies[ "SoftResData" ] = { ... }
    return self
  end

  -- EXTENSION: builds RollFor as if this addon were switched off in the options window,
  -- so a test can show what a drop looks like without the rotation.
  function builder.without_auto_robin( self )
    dependencies[ "WithoutAutoRobin" ] = true
    return self
  end

  ---@param threshold number
  -- Recorded rather than applied: build() resets the threshold, so applying it here would
  -- be undone by the very call it is meant to configure.
  function builder.loot_threshold( self, threshold )
    dependencies[ "LootThreshold" ] = threshold
    return self
  end

  function builder.build()
    u.mock_slashcmdlist() -- Drop the previous build's commands so this one can register its own.
    u.zone_name()
    u.loot_threshold( dependencies[ "LootThreshold" ] or 2 )
    u.targetting_enemy( "Princess Kenny" )

    local deps = dependencies or {}
    local db = Db.new( {} )

    local config = deps[ "Config" ] or M.mock_config()
    deps[ "Config" ] = config

    local player_info = require( "test/common/mocks/PlayerInfo" ).new( "Psikutas", "Warrior", true, true )
    deps[ "PlayerInfo" ] = player_info

    local group_roster_api = deps[ "GroupRosterApi" ] or M.mock_roster( { M.p( "Jogobobek", C.Warrior ), M.p( "Obszczymucha", C.Druid ) } )
    local group_roster = require( "src/GroupRoster" ).new( group_roster_api, player_info )
    deps[ "GroupRoster" ] = group_roster

    local chat_api = deps[ "ChatApi" ] or require( "mocks/ChatApi" ).new()
    local chat = deps[ "Chat" ] or require( "src/Chat" ).new( chat_api, group_roster, player_info )
    deps[ "Chat" ] = chat

    local loot_facade = deps[ "LootFacade" ] or M.mock_loot_facade()
    deps[ "LootFacade" ] = loot_facade

    local raw_awarded_loot = require( "src/AwardedLoot" ).new( db( "awarded_loot" ), chat )

    local softres, awarded_loot = group_aware_softres(
      group_roster, raw_awarded_loot, deps[ "SoftResData" ], deps[ "ExtendChains" ] )
    deps[ "SoftRes" ] = softres

    local raw_loot_list = require( "mocks/LootList" ).new( loot_facade )
    deps[ "LootList" ] = raw_loot_list
    local loot_list = require( "src/SoftResLootListDecorator" ).new( raw_loot_list, softres )
    deps[ "SoftResLootList" ] = loot_list

    local ml_candidates_api = deps[ "MasterLootCandidatesApi" ] or require( "test/common/mocks/MasterLootCandidatesApi" ).new( group_roster, raw_loot_list )
    local ml_candidates = require( "src/MasterLootCandidates" ).new( ml_candidates_api, group_roster, raw_loot_list )
    deps[ "MasterLootCandidates" ] = ml_candidates

    local ace_timer = require( "test/common/mocks/AceTimer" ).new()
    deps[ "AceTimer" ] = ace_timer

    local winner_tracker = require( "src/WinnerTracker" ).new( db( "winner_tracker" ) )
    deps[ "WinnerTracker" ] = winner_tracker

    local frame_builder = require( "mocks/FrameBuilder" )
    local loot_frame_skin = require( "test/common/mocks/MockedLootFrameSkin" ).new( frame_builder )
    local loot_frame = require( "mocks/LootFrame" ).new( loot_frame_skin, db( "loot_frame" ), config )
    local popup_builder = require( "mocks/PopupBuilder" )
    local rolling_popup = require( "mocks/RollingPopup" ).new( popup_builder.new(), db( "dummy" ), config )

    local confirmation_popup = require( "test/common/mocks/LootAwardPopup" ).new( nil )
    deps[ "LootAwardPopup" ] = confirmation_popup

    local player_selection_frame = require( "test/common/mocks/MasterLootCandidateSelectionFrame" ).new( frame_builder, config )
    deps[ "PlayerSelectionFrame" ] = player_selection_frame

    local roll_controller = require( "src/RollController" ).new(
      ml_candidates,
      softres,
      loot_list,
      config,
      rolling_popup,
      confirmation_popup, ---@diagnostic disable-line: param-type-mismatch
      player_selection_frame
    )

    local loot_award_callback = require( "src/LootAwardCallback" ).new( awarded_loot, roll_controller, winner_tracker, group_roster )
    local master_loot = require( "src/MasterLoot" ).new( ml_candidates, loot_award_callback, loot_list, roll_controller, player_info )

    -- Where main.lua registers them, and for its reason: an award by hand goes through the same
    -- callback master loot and trading do, so everything downstream hears it.
    u.modules().slash_cmd( "award", raw_awarded_loot.make_command( "/award", function( player_name, item_data )
      loot_award_callback.on_loot_awarded( item_data.item_id, item_data.link, player_name )
    end ) )

    u.modules().slash_cmd( "unaward", raw_awarded_loot.make_command( "/unaward", function( player_name, item_data )
      awarded_loot.unaward( player_name, item_data, true )
      roll_controller.loot_unawarded( item_data.item_id, item_data.link, player_name )
    end ) )
    deps[ "MasterLoot" ] = master_loot

    local strategy_factory = require( "src/RollingStrategyFactory" ).new(
      group_roster,
      loot_list,
      ml_candidates,
      chat,
      ace_timer,
      winner_tracker,
      config,
      softres,
      player_info
    )
    deps[ "RollingStrategyFactory" ] = strategy_factory

    local rolling_logic = RollingLogic.new(
      chat,
      ace_timer,
      roll_controller,
      strategy_factory,
      ml_candidates,
      winner_tracker,
      config
    )
    deps[ "RollingLogic" ] = rolling_logic

    local loot_controller = require( "src/LootController" ).new(
      player_info,
      loot_facade,
      loot_list,
      loot_frame,
      roll_controller,
      softres,
      rolling_logic,
      chat
    )
    deps[ "LootController" ] = loot_controller

    local rolling_popup_content = require( "src/RollingPopupContentTransformer" ).new( config )
    deps[ "RollingPopupContent" ] = rolling_popup_content

    require( "src/RollResultAnnouncer" ).new( chat, roll_controller, config )
    local boss_killed = deps[ "BossKilled" ] or require( "src/BossKilled" ).new( db( "boss_killed" ) )
    deps[ "BossKilled" ] = boss_killed

    -- EXTENSION: core's dropped-item predicates, which this addon contributes one to.
    local withhold = {}

    local dropped_loot = require( "src/DroppedLoot" ).new( db( "dummy" ), loot_list, player_info, boss_killed )
    local dropped_loot_announce = require( "src/DroppedLootAnnounce" ).new(
      loot_list,
      chat,
      softres,
      winner_tracker,
      player_info,
      withhold
    )

    -- EXTENSION: the real rotation, not a mock -- the award pass is most of what these
    -- specs are about, and there is nothing random left in it: the queue order decides the
    -- winner.
    local autorobin_db = db( "autorobin_db" )
    RollForAutoRobin.AutoRoundRobinDb.ensure_seeded( autorobin_db )

    local auto_round_robin = RollForAutoRobin.AutoRoundRobin.new(
      function() return u.modules().api end,
      autorobin_db,
      config,
      chat,
      group_roster,
      ml_candidates,
      loot_award_callback
    )

    deps[ "AutoRoundRobin" ] = auto_round_robin
    RollForAutoRobin.auto_round_robin = auto_round_robin

    local auto_group_loot = require( "test/common/mocks/AutoGroupLoot" ).new()
    local loot_facade_listener = require( "src/LootFacadeListener" ).new()

    -- The real one, not a stand-in: an addon registering an award policy has to have somewhere
    -- to register it, and core is what performs the award now.
    local award_policies = require( "src/AwardPolicies" ).new( db( "award_order" ) )
    award_policies.attach( loot_list, player_info, ml_candidates )

    -- EXTENSION: the addon's handlers go in through its own on_enable, not a copy of it --
    -- so a test proves the real registration puts them where they belong, rather than
    -- proving this file agrees with itself.
    if not deps[ "WithoutAutoRobin" ] then
      auto_robin.on_enable( {
        config = {
          register_toggle = function() end,
          register_number = function() end,
          auto_round_robin_announce_drops = config.auto_round_robin_announce_drops
        },
        gui_elements = m.GuiElements,
        award_policy = award_policies.register,
        loot_claim = award_policies.claim_of,
        on_dropped_item = function( predicate ) table.insert( withhold, predicate ) end,
        on_group_changed = function() end,
        on_new_group = function() end
      } )
    end

    require( "src/CoreLootHandlers" ).register( loot_facade_listener, {
      award_policies = award_policies,
      dropped_loot = dropped_loot,
      dropped_loot_announce = dropped_loot_announce,
      master_loot = master_loot,
      auto_group_loot = auto_group_loot,
      roll_controller = roll_controller
    } )

    loot_facade_listener.start( loot_facade )
    deps[ "LootFacadeListener" ] = loot_facade_listener

    require( "src/DebugBuffer" ).disable_all()
    deps.roll = rolling_logic.on_roll

    return {
      loot_frame = loot_frame,
      rolling_popup = rolling_popup,
      confirmation_popup = confirmation_popup,
      player_selection = player_selection_frame,
      loot_list = loot_list, ---@type LootList
      auto_round_robin = auto_round_robin, ---@type AutoRoundRobin
      round_robin_list = M.round_robin_list( autorobin_db ),
      autorobin_db = autorobin_db,
      dropped_loot = dropped_loot, ---@type DroppedLoot
      ace_timer = ace_timer,
      roll = rolling_logic.on_roll,
      roll_controller = roll_controller,
      awarded_loot = awarded_loot, ---@type AwardedLoot
      softres = softres, ---@type GroupAwareSoftRes
      reset_announcements = dropped_loot_announce.reset,
      enable_debug = enable_debug
    }
  end

  return builder
end

return M
