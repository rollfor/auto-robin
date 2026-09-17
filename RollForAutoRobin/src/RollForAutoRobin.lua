RollForAutoRobin = RollForAutoRobin or {}
local ar = RollForAutoRobin

-- Auto Round Robin, as a RollFor extension.
--
-- Hands selected items out in a strict, visible rotation instead of rolling for them. The
-- rotation itself lives in src/AutoRoundRobin.lua; this file is the integration surface.
--
-- It needs three things from core that a decorator-only extension does not: an award policy
-- (ctx.award_policy), a say in what gets announced as a drop (ctx.on_dropped_item), and its
-- settings (ctx.config.register_toggle/register_number). The drop predicate arrived with API
-- version 3, the selection tree with API 5. The tree is drawn on the Loot tab of this addon's
-- options page.
--
-- API 6 is the one that matters here: core performs the award now, so the rotation decides and
-- stops. It no longer asks RollForAutoLoot what it claims, because it no longer needs to know
-- that addon exists.
--
-- API 8 is ctx.open_options, which is how /rf autorobin brings the Loot tab up now that the list
-- is no longer a window of its own.
--
-- The registration below runs at file scope: the TOC declares `## Dependencies: RollFor`,
-- which makes the client load RollFor first and refuse to load this addon without it.

local M = {}

-- The options page, redrawn for something that changed under it: a queue moving, somebody joining
-- the group. The page only redraws when it is on screen, and may not have been
-- built at all yet.
local function refresh_options_page()
  if ar.options_page then ar.options_page.refresh() end
end

-- The published surface for display addons. The event name is kept exactly as it was when this
-- lived in core: it is what other people's auras subscribe to, and renaming it would break
-- strangers' auras silently.
---@param ctx ExtensionContext
---@param category string
local function broadcast( ctx, category )
  local weak_auras = ctx.api().WeakAuras

  if weak_auras and weak_auras.ScanEvents then
    weak_auras.ScanEvents( "ROLLFOR_ROUND_ROBIN_QUEUE_UPDATE", category )
  end
end

-- Every category at once, for a change that isn't one queue moving. Guarded because the options
-- page is built before on_ready builds the rotation, and nothing has categories to announce until
-- then.
---@param ctx ExtensionContext
local function broadcast_all( ctx )
  if not ar.auto_round_robin then return end

  for _, category in ipairs( ar.auto_round_robin.get_categories() ) do broadcast( ctx, category ) end
end

---@param ctx ExtensionContext
local function on_enable( ctx )
  -- Declared here rather than in on_ready because on_enable is the declaration phase and
  -- the options window reads these while building its rows.
  ctx.config.register_toggle( "auto_round_robin",
    { cmd = "auto-robin", display = "Auto round robin", help = "toggle auto round robin" }, true )

  -- Off by default, and deliberately so: when the rotation is handing an item out, the
  -- award announces it a moment later and the item was never up for grabs, so announcing
  -- the drop as well is just noise. Anyone who wants both can say so.
  ctx.config.register_toggle( "auto_round_robin_announce_drops",
    { cmd = "auto-robin-announce-drops", display = "Announce auto round robin drops",
      help = "toggle announcing items the rotation will hand out" }, false )

  ctx.config.register_toggle( "auto_round_robin_announce",
    { cmd = "auto-robin-announce", display = "Announce auto round robin awards",
      help = "toggle announcing auto round robin awards" }, true )

  -- This addon's row widgets, into the table FrameBuilder resolves rows against. Here rather
  -- than in on_ready because the windows built there look their rows up by name as they draw.
  ar.RoundRobinWidgets.register( ctx.gui_elements )

  -- An award policy rather than a loot handler that awards. Core walks the slots, runs the
  -- registered policies in whatever order the user has put them in, sends the award and
  -- records who took the slot -- which is what this used to reach through a global for.
  --
  -- `after = "auto_loot"` said "conflicts resolve in auto-loot's favour": a priority, spelled
  -- as a schedule, naming an addon that need not be installed. The rule has not been dropped,
  -- it has been handed over -- it is a list the user can reorder, and neither addon names the
  -- other any more.
  --
  -- Guarded because the rotation is built in on_ready and core calls this at loot time, so
  -- registering here is correct and arriving early is normal.
  ctx.award_policy( {
    name = "auto_robin",
    title = "Round robin",
    decide = function( slot, item )
      if not ar.auto_round_robin then return end

      return ar.auto_round_robin.decide( slot, item )
    end,
    on_awarded = function( slot, item, recipient )
      if ar.auto_round_robin then ar.auto_round_robin.on_awarded( slot, item, recipient ) end
    end
  } )

  -- Core cannot ask whether an item is the rotation's, so the rotation answers.
  ctx.on_dropped_item( function( item )
    if not ar.auto_round_robin then return end
    if ar.auto_round_robin.is_round_robined( item ) and not ctx.config.auto_round_robin_announce_drops() then
      return false
    end
  end )

  ctx.on_group_changed( function()
    if ar.auto_round_robin then ar.auto_round_robin.on_group_changed() end
    -- The queues are read fresh on every draw, so redrawing is all it takes for someone who joined
    -- to appear.
    refresh_options_page()
  end )
end

---@param ctx ExtensionContext
local function on_ready( ctx )
  local db = ctx.db( "db", {
    -- 1 -> 2. Queues written before players carried a core flag, so there is no telling which
    -- of their rows were added by hand and which the roster swept in. Guessing either way is
    -- worse than starting over: calling them all core makes last month's pugs permanent,
    -- calling them all transient throws away the hand-added players the flag exists to
    -- protect. The order is rebuilt from the group on the next roster update.
    function( store ) store.queues = nil end
  } )

  ar.AutoRoundRobinDb.ensure_seeded( db )

  ar.auto_round_robin = ar.AutoRoundRobin.new(
    ctx.api,
    db,
    ctx.config,
    ctx.chat,
    ctx.group_roster,
    ctx.get( "master_loot_candidates" ),
    ctx.get( "loot_award_callback" )
  )

  ar.auto_round_robin.subscribe( function( category ) broadcast( ctx, category ) end )

  -- Switching the feature off stops every category handing anything out, which is as much a
  -- reason to redraw as the queue moving or a row being ticked.
  ctx.config.subscribe( "auto_round_robin", function() broadcast_all( ctx ) end )

  -- RollForApi is kept exactly as it was when this lived in core, for the same reason as the
  -- event: it is deliberately a separate global from RollFor -- which is a module table free to
  -- change shape -- precisely so it can survive a move like this one.
  ---@diagnostic disable-next-line: lowercase-global
  RollForApi = RollForApi or {}
  RollForApi.round_robin = {
    categories = function() return ar.auto_round_robin.get_categories() end,
    is_active = function( category ) return ar.auto_round_robin.is_category_active( category ) end,
    queue = function( category, limit ) return ar.auto_round_robin.get_rows( category, limit ) end
  }

  ar.simulator = ar.AutoRoundRobinSimulator.new( db, ctx.group_roster )

  -- Every award and every edit moves somebody, and a queue tab may well be open while a loot
  -- window is.
  ar.auto_round_robin.subscribe( refresh_options_page )

  ar.add_player_frame = ar.AutoRoundRobinAddPlayerFrame.new( ctx.popup_builder(), ar.auto_round_robin,
    ctx.group_roster, refresh_options_page )

  local function confirm_reset()
    if ar.auto_round_robin.is_pristine() then
      ar.auto_round_robin.reset()
      return
    end

    ctx.get( "confirmation_dialog" ).show( {
      message = "This will clear every round-robin queue.",
      confirm = "Reset",
      on_confirm = function() ar.auto_round_robin.reset() end
    } )
  end

  -- The settings, the list and the queues are all on this addon's options page, each on a tab of
  -- its own. The tab is picked first, so the page draws it when the window shows it -- always,
  -- since the page otherwise opens on whichever tab was left open.
  ---@param label string
  local function open_tab( label )
    if ar.options_page then ar.options_page.select_tab( label ) end

    ctx.open_options()
  end

  -- Which queue tab each queue is on, by the queue's name as typed: `/rf autorobin gems` opens the
  -- tab Gems is on. Read off the page's own list, so a queue moving tabs moves its command with it.
  ---@type table<string, string>
  local queue_tabs = {}
  local choices = { "loot" }

  for _, queue_tab in ipairs( ar.OptionsPage.QUEUE_TABS ) do
    for _, category in ipairs( queue_tab.categories ) do
      queue_tabs[ string.lower( category ) ] = queue_tab.label
      table.insert( choices, string.lower( category ) )
    end
  end

  table.insert( choices, "reset" )

  local usage = string.format( "Usage: %s", ar.OptionsPage.command_choices( "/rf autorobin", choices ) )

  -- A subcommand of core's /rf, so these open the way every other RollFor window does. Core
  -- matches the first word and hands the rest over unparsed, so the word after it is ours to pick
  -- out: nothing opens the settings, `loot` the list, a queue's name that queue's tab, and `reset`
  -- resets. Anything else is a typo, and opening the page for it would hide that.
  ctx.on_rf_command( "autorobin", function( args )
    local word = string.lower( string.match( args or "", "^%s*(%S*)" ) )

    if word == "" then
      open_tab( "General" )
    elseif word == "loot" then
      open_tab( "Loot" )
    elseif queue_tabs[ word ] then
      open_tab( queue_tabs[ word ] )
    elseif word == "reset" then
      confirm_reset()
    else
      RollFor.info( usage )
    end
  end )
end

function M.register()
  if not RollFor.Extensions then
    RollFor.warn( "Unsupported RollFor version.", "RollForAutoRobin" )
    return
  end

  return RollFor.Extensions.register( {
    name = "auto_robin",
    title = "Auto Round Robin",
    api_version = 8,
    default_enabled = true,

    -- This addon is the feature, and "Auto round robin" already says whether it does anything.
    -- A switch above that one asks the same question twice, and the two could disagree --
    -- Auto round robin ticked on a disabled extension reads as broken. Core draws no switch
    -- and keeps us on; the way to be rid of it entirely is the game's own AddOns list.
    hide_enabled_option = true,
    on_enable = on_enable,
    on_ready = on_ready,

    -- Core creates the canvas and asks us to fill it in. Declared here rather than from
    -- on_enable because the page is built whether or not on_enable ever ran: an extension
    -- built against an API core does not have never gets enabled, and still gets a page.
    --
    -- Kept, because /rf autorobin has to be able to tell it which tab to open on, and the rotation
    -- has to be able to redraw it.
    --
    -- The rotation and the add-player form are handed over as getters: core builds the page
    -- before on_ready builds either. Ticking a category row flips the same flag
    -- is_category_active reads, so a display addon watching is_active would go stale until the
    -- queue happened to move; it gets the same broadcast on_ready gives the queue moving and the
    -- feature being switched off.
    options_page = function( ctx, parent )
      ar.options_page = ar.OptionsPage.new( ctx, parent, {
        on_selection_changed = function() broadcast_all( ctx ) end,
        round_robin = function() return ar.auto_round_robin end,
        add_player = function( category )
          if ar.add_player_frame then ar.add_player_frame.show( category ) end
        end
      } )

      return ar.options_page
    end
  } )
end

M.on_enable = on_enable
M.on_ready = on_ready

ar.main = M

-- Registration happens on load, which is the whole point: by the time RollFor builds its
-- components on PLAYER_LOGIN, the registry already knows about us. Tests that want a clean
-- registry clear it and call M.register() again.
M.register()

return M
