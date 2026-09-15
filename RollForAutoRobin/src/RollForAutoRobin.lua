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
-- version 3, the selection tree and the window that draws it with API 5.
--
-- API 6 is the one that matters here: core performs the award now, so the rotation decides and
-- stops. It no longer asks RollForAutoLoot what it claims, because it no longer needs to know
-- that addon exists.
--
-- The registration below runs at file scope: the TOC declares `## Dependencies: RollFor`,
-- which makes the client load RollFor first and refuse to load this addon without it.

local M = {}

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

  ctx.config.register_number( "round_robin_queue_rows", 10, 5, 20 )

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
    if ar.queue_frame then ar.queue_frame.on_group_changed() end
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

  -- The published surface for display addons. Both names are kept exactly as they were when
  -- this lived in core: the event is what other people's auras subscribe to, and RollForApi
  -- is deliberately a separate global from RollFor -- which is a module table free to change
  -- shape -- precisely so it can survive a move like this one. Renaming either would break
  -- strangers' auras silently.
  local function broadcast( category )
    local weak_auras = ctx.api().WeakAuras

    if weak_auras and weak_auras.ScanEvents then
      weak_auras.ScanEvents( "ROLLFOR_ROUND_ROBIN_QUEUE_UPDATE", category )
    end
  end

  ar.auto_round_robin.subscribe( broadcast )

  local function broadcast_all()
    for _, category in ipairs( ar.auto_round_robin.get_categories() ) do broadcast( category ) end
  end

  -- Switching the feature off stops every category handing anything out, which is as much a
  -- reason to redraw as the queue moving or a row being ticked.
  ctx.config.subscribe( "auto_round_robin", broadcast_all )

  ---@diagnostic disable-next-line: lowercase-global
  RollForApi = RollForApi or {}
  RollForApi.round_robin = {
    categories = function() return ar.auto_round_robin.get_categories() end,
    is_active = function( category ) return ar.auto_round_robin.is_category_active( category ) end,
    queue = function( category, limit ) return ar.auto_round_robin.get_rows( category, limit ) end
  }

  ar.simulator = ar.AutoRoundRobinSimulator.new( db, ctx.group_roster )

  local queue_transformer = ar.AutoRoundRobinQueueFrameContentTransformer.new()

  ar.add_player_frame = ar.AutoRoundRobinAddPlayerFrame.new( ctx.popup_builder(),
    ctx.group_roster, ar.auto_round_robin )

  ar.queue_frame = ar.AutoRoundRobinQueueFrame.new( ctx.popup_builder(), queue_transformer,
    ar.auto_round_robin, ar.add_player_frame, ctx.config, ctx.db( "queue_frame" ) )

  -- The last argument is on_changed: ticking a category row flips the same flag
  -- is_category_active reads, so a display addon watching is_active would go stale until the
  -- queue happened to move. It is the third reason to redraw the comment above names.
  ar.frame = ar.AutoRoundRobinFrame.new( ctx.selection_tree, ctx.selection_tree_frame,
    ctx.popup_builder(), db, ctx.db( "frame" ), function() ar.queue_frame.toggle() end,
    broadcast_all )

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

  -- A subcommand of core's /rf, so these windows open the way every other RollFor window
  -- does. Core matches the first word and hands the rest over unparsed, so `queue` and
  -- `reset` are ours to pick out -- and both are matched before the bare form, which would
  -- otherwise swallow them.
  ctx.on_rf_command( "autorobin", function( args )
    args = args or ""

    if string.find( args, "^queue" ) then
      ar.queue_frame.toggle()
      return
    end

    if string.find( args, "^reset" ) then
      confirm_reset()
      return
    end

    ar.frame.toggle()
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
    api_version = 6,
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
    options_page = function( ctx, parent ) return ar.OptionsPage.new( ctx, parent ) end
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
