package.path = "./?.lua;" .. package.path .. ";../../deps/rollfor/RollFor/src/?.lua;../../deps/rollfor/RollFor/src/libs/?.lua;../src/?.lua;../../?.lua;../../deps/rollfor/?.lua"

-- This addon builds its own page in RollFor's options window. Core supplies the canvas
-- and the builders and asks for it; what ends up on it is entirely ours, which is the
-- point -- an extension keeps its own database, so core cannot know what belongs there. The
-- list of what the rotation hands out and the queues used to be windows of their own, and are the
-- page's Loot and queue tabs now.
--
-- The doubles are local rather than borrowed from RollFor's test harness. Core's options
-- tests spy on its content transformer, which this page does not use: it talks to the
-- popup builder directly. Owning the page means owning the double for it.

require( "src/compat" )
local u = require( "RollForAutoRobin/test/utils" )
local lu, eq = u.luaunit( "assertEquals" )
require( "src/modules" )
u.multi_require_src( "DebugBuffer", "Module", "Types" )

-- Before the catalogue is required: it reads the client's quality colours at load time, which in
-- the real client are set during UIParent load, well before any addon file runs.
u.mock_wow_api()
require( "src/ItemUtils" )
require( "src/Tree" )
require( "src/SelectionTree" )
u.load_extension()

local OptionsPage = RollForAutoRobin.OptionsPage
local AutoRoundRobinDb = RollForAutoRobin.AutoRoundRobinDb
local ItemQuality = RollFor.Types.ItemQuality

-- Widgets that record what was done to them, so a test can ask what the page put on a
-- line rather than what it looks like on screen. What the real widgets draw is RollFor's
-- business, and the game's.
local function fake_widget()
  local widget = {}

  widget.SetText = function( _, text ) widget.text = text end
  widget.SetChecked = function( _, checked ) widget.checked = checked end
  widget.SetTabs = function( _, labels, selected )
    widget.labels = labels
    widget.selected = selected
  end
  widget.SetWidth = function( _, width ) widget.width = width end
  widget.GetWidth = function() return widget.width or 0 end
  widget.GetHeight = function() return 20 end
  widget.ClearAllPoints = function() end
  widget.SetPoint = function() end
  widget.Show = function() end
  widget.Hide = function() end

  return widget
end

-- A row of the list. Only the methods the real tree_node widget has, and nothing else, so a
-- call the widget would not answer fails here rather than in the game.
local function fake_tree_node()
  local row = {}

  row.SetDepth = function( _, depth ) row.depth = depth end
  row.SetExpandable = function( _, expandable, expanded )
    row.expandable = expandable
    row.expanded = expanded
  end
  row.SetChecked = function( _, checked ) row.checked = checked end
  row.SetDesaturated = function( _, desaturated ) row.desaturated = desaturated end
  row.SetItem = function( _, item, tooltip_link )
    row.item = item
    row.tooltip_link = tooltip_link
    row.text = nil
  end
  row.SetText = function( _, text )
    row.text = text
    row.item = nil
  end
  row.SetLabelStyle = function( _, color ) row.color = color end
  row.SetLabelTooltip = function( _, lines ) row.tooltip_text = lines end
  row.SetWidth = function() end
  row.SetHeight = function() end
  row.GetWidth = function() return 0 end
  row.GetHeight = function() return 14 end
  row.ClearAllPoints = function() end
  row.SetPoint = function() end

  return row
end

-- A queue's lines: this addon's own rows, and core's button. What they draw is RoundRobinWidgets'
-- and core's; what matters here is what the page handed them.
local function fake_queue_widget()
  local widget = fake_widget()

  widget.SetHeader = function( _, header ) widget.header = header end
  widget.SetRow = function( _, row ) widget.row = row end
  widget.SetHeight = function() end
  widget.SetScale = function() end
  widget.SetScript = function( _, script, callback ) widget[ script ] = callback end

  return widget
end

-- A queue's search box. Putting text in fires on_change, the way the client fires OnTextChanged for
-- text set from code as much as for text typed, and typing is putting text in.
local function fake_text_field()
  local field = fake_widget()

  field.value = ""
  field.set_value_count = 0

  field.GetHeight = function() return 18 end
  field.SetPoint = function( _, point, relative_frame, relative_point, x, y )
    field.anchor = { point = point, relative_frame = relative_frame, relative_point = relative_point, x = x, y = y }
  end
  field.SetFieldWidth = function( _, width ) field.field_width = width end
  field.SetMaxLetters = function( _, max ) field.max_letters = max end
  field.GetValue = function() return field.value end

  field.SetValue = function( _, value )
    field.set_value_count = field.set_value_count + 1
    field.value = value or ""
    if field.on_change then field.on_change( field.value ) end
  end

  field.type = function( text )
    field.value = text
    if field.on_change then field.on_change( text ) end
  end

  return field
end

local function fake_gui_elements()
  local elements = {}

  for _, line_type in ipairs( { "section_header", "paragraph", "tabs", "checkbox" } ) do
    elements[ line_type ] = fake_widget
  end

  for _, line_type in ipairs( { "round_robin_count", "round_robin_row", "text", "button" } ) do
    elements[ line_type ] = fake_queue_widget
  end

  elements.tree_node = fake_tree_node
  elements.text_field = fake_text_field

  return elements
end

-- A popup that keeps its lines, which is the whole of what this page does with one. Scrolls the
-- way the real one does: a line of a scrolling type outside the window is dropped, and the
-- caller is told by getting nil back.
local function recording_popup_builder()
  local builder = {}
  local popup = { lines = {}, visible = false }
  local elements = {}
  local scrolling, on_scroll
  local scroll = { offset = 0, total = 0, index = 0 }

  -- A type or a list of them, the way the real builder takes it.
  local function scrolls( line_type )
    if not scrolling then return false end
    if type( scrolling.line_types ) ~= "table" then return scrolling.line_types == line_type end

    for _, scrolling_type in ipairs( scrolling.line_types ) do
      if scrolling_type == line_type then return true end
    end

    return false
  end

  local function is_scrolled_out( line_type )
    if not scrolls( line_type ) then return false end

    scroll.index = scroll.index + 1

    return scroll.index <= scroll.offset or scroll.index > scroll.offset + scrolling.max_lines
  end

  local function max_offset()
    local result = scroll.total - (scrolling and scrolling.max_lines or 0)
    return result > 0 and result or 0
  end

  popup.add_line = function( line_type, modify_fn, padding )
    if is_scrolled_out( line_type ) then return end

    local frame = (elements[ line_type ] or fake_widget)()
    modify_fn( line_type, frame, popup.lines )

    local line = { line_type = line_type, frame = frame, padding = padding }
    table.insert( popup.lines, line )

    return line
  end

  popup.set_scroll_total = function( _, total )
    scroll.total = total
    if scroll.offset > max_offset() then scroll.offset = max_offset() end
  end

  popup.get_scroll = function()
    return { offset = scroll.offset, total = scroll.total, max_lines = scrolling and scrolling.max_lines or 0 }
  end

  popup.scroll_by = function( _, delta )
    local offset = math.min( math.max( scroll.offset + delta, 0 ), max_offset() )
    if offset == scroll.offset then return end

    scroll.offset = offset
    if on_scroll then on_scroll() end
  end

  popup.clear = function()
    popup.lines = {}
    scroll.index = 0
  end
  popup.hide_count = 0
  popup.Show = function() popup.visible = true end
  popup.Hide = function()
    popup.visible = false
    popup.hide_count = popup.hide_count + 1
  end
  popup.IsVisible = function() return popup.visible end
  popup.SetBackdrop = function( _, backdrop ) popup.backdrop = backdrop end
  popup.SetBackdropColor = function() end
  popup.SetBackdropBorderColor = function() end
  popup.ClearAllPoints = function() popup.anchor = nil end
  popup.SetPoint = function( _, point, relative_frame, relative_point, x, y )
    popup.anchor = { point = point, relative_frame = relative_frame, relative_point = relative_point, x = x, y = y }
  end
  popup.SetWidth = function( _, width ) popup.width = width end
  popup.SetHeight = function( _, height ) popup.height = height end

  -- A texture that keeps where it was put, how big it is and whether it is showing.
  popup.CreateTexture = function()
    local texture = { visible = true }

    texture.SetTexture = function() end
    texture.SetVertexColor = function() end
    texture.ClearAllPoints = function() texture.anchor = nil end
    texture.SetPoint = function( _, point, relative_frame, relative_point, x, y )
      texture.anchor = { point = point, relative_frame = relative_frame, relative_point = relative_point, x = x, y = y }
    end
    texture.SetWidth = function( _, width ) texture.width = width end
    texture.SetHeight = function( _, height ) texture.height = height end
    texture.Show = function() texture.visible = true end
    texture.Hide = function() texture.visible = false end

    return texture
  end

  -- Every setter the page chains, answering with itself.
  for _, setter in ipairs( { "name", "parent", "point", "backdrop_color", "no_border" } ) do
    builder[ setter ] = function( self ) return self end
  end

  builder.gui_elements = function( self, value )
    elements = value
    return self
  end

  builder.scrollable = function( self, opts )
    scrolling = opts
    return self
  end

  builder.on_scroll = function( self, callback )
    on_scroll = callback
    return self
  end

  builder.build = function() return popup end

  return builder
end

-- What core hands over: the builders, this extension's own on/off state, the config its
-- settings were registered into, the selection tree, and this extension's db, seeded the way
-- on_ready seeds it. Not the summary -- that is ours, and lives in the page.
---@param overrides table?
local function mock_context( overrides )
  -- The Loot tab reads the master loot threshold whenever it draws a quality row. Uncommon is
  -- the lowest the client offers, so nothing is greyed unless a test raises it.
  u.loot_threshold( ItemQuality.Uncommon )

  local store = {}
  AutoRoundRobinDb.ensure_seeded( store )

  -- Every other db this extension asks for, by key, empty until something writes to it.
  local dbs = { db = store }

  local state = { enabled = true, set_to = nil, settings = {
    auto_round_robin = true,
    auto_round_robin_announce = true,
    auto_round_robin_announce_drops = false,
    auto_round_robin_new_group_reset = true
  } }

  local config = {}

  for key in pairs( state.settings ) do
    config[ key ] = function() return state.settings[ key ] end
    config[ "set_" .. key ] = function( value ) state.settings[ key ] = value end
  end

  local ctx = {
    popup_builder = recording_popup_builder,
    gui_elements = fake_gui_elements(),
    config = config,
    selection_tree = RollFor.SelectionTree,
    db = function( key )
      dbs[ key ] = dbs[ key ] or {}
      return dbs[ key ]
    end,
    store = store,
    is_enabled = function() return state.enabled end,
    set_enabled = function( value )
      state.set_to = value
      state.enabled = value
    end,
    state = state
  }

  for key, value in pairs( overrides or {} ) do ctx[ key ] = value end

  return ctx
end

local CANVAS_WIDTH = 665

---@param ctx table
---@param deps AutoRobinOptionsPageDeps?
local function shown_page( ctx, deps )
  local canvas = u.modules().api.CreateFrame( "Frame" )
  canvas.GetWidth = function() return CANVAS_WIDTH end

  local page = OptionsPage.new( ctx, canvas, deps )
  page.show()

  return page
end

-- Every line on the page, the summary and the tabs first and then what is in the panel under
-- them, in the order they read.
---@return table[]
local function all_lines( page )
  local result = {}

  for _, frame in ipairs( { page.get_frame(), page.get_panel() } ) do
    for _, entry in ipairs( frame.lines ) do table.insert( result, entry ) end
  end

  return result
end

---@return string[]
local function line_types( page )
  local result = {}

  for _, line in ipairs( all_lines( page ) ) do
    table.insert( result, line.line_type )
  end

  return result
end

---@return table
local function line( page, line_type )
  for _, entry in ipairs( all_lines( page ) ) do
    if entry.line_type == line_type then return entry.frame end
  end

  error( string.format( "There was no %s on the page.", line_type ), 2 )
end

---@return table
local function checkbox( page, label )
  for _, entry in ipairs( all_lines( page ) ) do
    if entry.line_type == "checkbox" and entry.frame.text == label then return entry.frame end
  end

  error( string.format( "There was no %q checkbox on the page.", label ), 2 )
end

-- The rows of the list that are on screen, top to bottom.
---@return table[]
local function rows( page )
  local result = {}

  for _, entry in ipairs( page.get_panel().lines ) do
    if entry.line_type == "tree_node" then table.insert( result, entry.frame ) end
  end

  return result
end

---@return string[]
local function row_names( page )
  local result = {}

  for _, frame in ipairs( rows( page ) ) do
    table.insert( result, frame.text or frame.item.link )
  end

  return result
end

---@return table
local function row( page, text )
  for _, frame in ipairs( rows( page ) ) do
    if frame.text == text then return frame end
  end

  error( string.format( "There was no %q row on the page.", text ), 2 )
end

---@param label string
local function select_tab( page, label )
  local tabs = line( page, "tabs" )

  for index, tab_label in ipairs( tabs.labels ) do
    if tab_label == label then return tabs.on_select( index ) end
  end

  error( string.format( "There was no %q tab on the page.", label ), 2 )
end

-- The Loot tab, which opens with Trash open, at the given loot threshold. Trash is ticked, so the only thing
-- left that can grey a row underneath it is the threshold. A row under an unchecked category is
-- greyed too (that's the tree's own rule, covered in SelectionTree_test), and leaving it off
-- here would make every threshold assertion below say nothing.
---@param threshold number
local function trash_open( threshold )
  local ctx = mock_context()
  ctx.store.ids[ AutoRoundRobinDb.TRASH ].enabled = true
  u.loot_threshold( threshold )

  local page = shown_page( ctx )
  select_tab( page, "Loot" )

  return page
end

OptionsPageSpec = {}

-- Summary first, tabs second, and the General tab open: a checkbox means nothing until you
-- know what it is you would be turning on.
function OptionsPageSpec:should_show_a_summary_then_the_general_tab()
  local page = shown_page( mock_context() )

  eq( line_types( page ), { "section_header", "paragraph", "tabs", "checkbox", "checkbox", "checkbox", "checkbox" } )
end

-- This addon's own copy, not something core handed over. Matched on what the rotation
-- actually does rather than the opening line, which is the part most likely to get
-- reworded.
function OptionsPageSpec:should_say_what_the_rotation_does()
  local summary = line( shown_page( mock_context() ), "paragraph" ).text

  eq( string.find( summary, "rotation", 1, true ) ~= nil, true )
  eq( string.find( summary, "One queue per category", 1, true ) ~= nil, true )
end

-- The list and the queues are tabs now, but the commands still open them straight on the right
-- one, so the summary is where a player finds out what they are.
function OptionsPageSpec:should_say_how_to_open_the_list_and_the_queues()
  local summary = line( shown_page( mock_context() ), "paragraph" ).text

  eq( string.find( summary, "/rf autorobin loot", 1, true ) ~= nil, true )
  -- The words highlighted, the brackets and bars between them white, and the bars doubled: a bar on
  -- its own would start an escape sequence in the client.
  local white, hl = RollFor.colors.white, RollFor.colors.hl
  local choices = hl( "/rf autorobin" ) .. " " .. white( "[" ) .. hl( "hearts" ) .. white( "||" ) .. hl( "marks" )
      .. white( "||" ) .. hl( "gems" ) .. white( "||" ) .. hl( "trash" ) .. white( "]" )

  eq( string.find( summary, choices, 1, true ) ~= nil, true )
end

TabsSpec = {}

function TabsSpec:should_offer_general_then_loot()
  local tabs = line( shown_page( mock_context() ), "tabs" )

  eq( tabs.labels, { "General", "Loot", "Hearts/Marks", "Gems/Trash" } )
  eq( tabs.selected, 1 )
end

-- The summary stays put whichever tab is open; only what is under the tabs changes.
function TabsSpec:should_show_the_loot_tab_under_the_same_summary()
  local page = shown_page( mock_context() )

  select_tab( page, "Loot" )

  local types = line_types( page )
  eq( { types[ 1 ], types[ 2 ], types[ 3 ] }, { "section_header", "paragraph", "tabs" } )
  eq( line( page, "tabs" ).selected, 2 )
  eq( string.find( line( page, "paragraph" ).text, "rotation", 1, true ) ~= nil, true )
  eq( #rows( page ) > 0, true )
  eq( #rows( page ), #page.get_panel().lines )
end

function TabsSpec:should_switch_back_to_the_general_tab()
  local page = shown_page( mock_context() )

  select_tab( page, "Loot" )
  select_tab( page, "General" )

  eq( line_types( page ), { "section_header", "paragraph", "tabs", "checkbox", "checkbox", "checkbox", "checkbox" } )
  eq( checkbox( page, "Auto round robin" ).checked, true )
end

-- Coming back to the settings window finds the page on the tab it was left on.
function TabsSpec:should_keep_the_open_tab_between_visits()
  local page = shown_page( mock_context() )

  select_tab( page, "Loot" )
  page.show()

  eq( line( page, "tabs" ).selected, 2 )
  eq( rows( page )[ 1 ].text, "Marks" )
end

-- What /rf autorobin does before it opens the window: the page is drawn on that tab when the
-- window shows it.
function TabsSpec:should_open_on_the_tab_it_is_told_to()
  local canvas = u.modules().api.CreateFrame( "Frame" )
  canvas.GetWidth = function() return CANVAS_WIDTH end
  local page = OptionsPage.new( mock_context(), canvas )

  page.select_tab( "Loot" )
  page.show()

  eq( line( page, "tabs" ).selected, 2 )
end

-- The window only redraws a page when it switches to it, so a page already on screen redraws
-- itself.
function TabsSpec:should_switch_straight_away_when_it_is_already_on_screen()
  local page = shown_page( mock_context() )

  page.select_tab( "Loot" )

  eq( line( page, "tabs" ).selected, 2 )
  eq( rows( page )[ 1 ].text, "Marks" )
end

LootTabSpec = {}

-- The categories that are closed, in the order they are drawn.
---@return string[]
local function closed_categories( page )
  local result = {}

  for _, frame in ipairs( rows( page ) ) do
    if frame.expandable and not frame.expanded then table.insert( result, frame.text ) end
  end

  return result
end

-- The same extension's page, built again over the same dbs: what a reload does.
---@param ctx table
local function reloaded_page( ctx )
  local page = shown_page( ctx )
  select_tab( page, "Loot" )

  return page
end

-- Everything open the first time, so the whole catalogue is on screen before anybody has clicked
-- anything, and in catalogue order.
function LootTabSpec:should_open_every_category_the_first_time()
  local page = shown_page( mock_context() )
  select_tab( page, "Loot" )

  eq( closed_categories( page ), {} )
  eq( row( page, "Marks" ).depth, 0 )
  eq( row( page, "Uncommon" ).depth, 1 )
  eq( row( page, "Trash Ignored" ).depth, 0 )
end

-- The quality rows are Trash's children, and closing it takes them off the list.
function LootTabSpec:should_close_a_row_when_it_is_clicked()
  local page = shown_page( mock_context() )
  select_tab( page, "Loot" )

  row( page, "Trash" ).on_click()

  local names = row_names( page )
  local trash

  for i, name in ipairs( names ) do
    if name == "Trash" then trash = i end
  end

  eq( closed_categories( page ), { "Trash" } )
  eq( names[ trash + 1 ], "Trash Ignored" )
end

function LootTabSpec:should_keep_closed_rows_closed_between_visits()
  local page = shown_page( mock_context() )
  select_tab( page, "Loot" )

  row( page, "Trash" ).on_click()
  page.show()

  eq( closed_categories( page ), { "Trash" } )
end

-- Written down, so it outlives the page: a reload builds the page again and it opens the way it
-- was left.
function LootTabSpec:should_remember_closed_rows_after_a_reload()
  local ctx = mock_context()
  local page = reloaded_page( ctx )

  row( page, "Gems" ).on_click()
  row( page, "Trash Ignored" ).on_click()

  eq( closed_categories( reloaded_page( ctx ) ), { "Gems", "Trash Ignored" } )
end

function LootTabSpec:should_remember_a_row_opened_again_after_a_reload()
  local ctx = mock_context()
  local page = reloaded_page( ctx )

  row( page, "Gems" ).on_click()
  row( page, "Gems" ).on_click()

  eq( closed_categories( reloaded_page( ctx ) ), {} )
  eq( ctx.db( "loot_tab" ).collapsed, {} )
end

-- In a db of its own. The selection db is what the rotation reads, and which rows are open is
-- nothing it has any use for.
function LootTabSpec:should_keep_the_open_rows_out_of_the_selection()
  local ctx = mock_context()
  local page = reloaded_page( ctx )

  row( page, "Gems" ).on_click()

  eq( ctx.db( "loot_tab" ).collapsed, { Gems = true } )
  eq( ctx.store.ids[ "Gems" ].expanded, nil )
end

-- Only the closed rows are written down, so a category the catalogue gains later opens the way
-- every category did the first time.
function LootTabSpec:should_open_a_category_the_catalogue_gained_since()
  local ctx = mock_context()
  row( reloaded_page( ctx ), "Gems" ).on_click()

  ctx.store.ids[ "Shards" ] = { enabled = false, order = 4, items = {} }
  ctx.store.ids[ "Shards" ].items[ 32208 ] = { enabled = false, quality = 4, icon = 1, name = "Shard" }

  eq( closed_categories( reloaded_page( ctx ) ), { "Gems" } )
end

-- A category taken out of the catalogue has no row left to open, so what was written about it
-- goes too.
function LootTabSpec:should_forget_a_category_the_catalogue_lost()
  local ctx = mock_context()
  local page = reloaded_page( ctx )

  row( page, "Gems" ).on_click()
  row( page, "Hearts" ).on_click()
  ctx.store.ids[ "Hearts" ] = nil
  reloaded_page( ctx )

  eq( ctx.db( "loot_tab" ).collapsed, { Gems = true } )
end

-- Ticking a row is the whole point of the list: it is what the rotation reads.
function LootTabSpec:should_write_a_ticked_row_back_to_the_db()
  local ctx = mock_context()
  local page = shown_page( ctx )
  select_tab( page, "Loot" )

  row( page, "Marks" ).on_check( true )

  eq( ctx.store.ids[ "Marks" ].enabled, true )
  eq( row( page, "Marks" ).checked, true )
end

-- An item is drawn as its link, so it has the item's tooltip rather than a bare name.
function LootTabSpec:should_draw_an_item_as_its_link()
  local page = shown_page( mock_context() )
  select_tab( page, "Loot" )

  local item = rows( page )[ 2 ].item

  eq( type( item.link ), "string" )
  eq( string.find( item.link, "|Hitem:32897", 1, true ) ~= nil, true )
end

-- Ticking a row changes whether the category hands anything out, which display addons need to
-- hear about. Nothing else notices the write: it goes straight onto the persisted entry through
-- SelectionTree.set_checked, with no db watch behind it.
function LootTabSpec:should_report_a_row_being_ticked()
  local changes = 0
  local page = shown_page( mock_context(), { on_selection_changed = function() changes = changes + 1 end } )
  select_tab( page, "Loot" )

  row( page, "Marks" ).on_check( true )

  eq( changes, 1 )
end

-- Told after the write, so a listener reading the selection sees the one it landed on.
function LootTabSpec:should_report_a_tick_after_writing_it()
  local ctx = mock_context()
  local seen
  local page = shown_page( ctx, { on_selection_changed = function() seen = ctx.store.ids[ "Marks" ].enabled end } )
  select_tab( page, "Loot" )

  row( page, "Marks" ).on_check( true )

  eq( seen, true )
end

-- Closing or opening a category is not a selection change: nothing about what gets handed out is
-- different.
function LootTabSpec:should_not_report_merely_closing_a_category()
  local changes = 0
  local page = shown_page( mock_context(), { on_selection_changed = function() changes = changes + 1 end } )
  select_tab( page, "Loot" )

  row( page, "Trash" ).on_click()

  eq( changes, 0 )
end

-- The Trash category's rows name a quality, and a quality below the master loot threshold can't
-- be handed out at all.
LootThresholdSpec = {}

-- Both rows are live at an Uncommon threshold: GiveMasterLoot will take either.
function LootThresholdSpec:should_leave_both_rows_alone_when_the_threshold_is_uncommon()
  local page = trash_open( ItemQuality.Uncommon )

  eq( row( page, "Uncommon" ).desaturated, false )
  eq( row( page, "Uncommon" ).tooltip_text, nil )
  eq( row( page, "Rare" ).desaturated, false )
  eq( row( page, "Rare" ).tooltip_text, nil )
end

-- At a Rare threshold the Uncommon row can't do anything, however it's ticked -- the award pass
-- drops the item before it ever asks which queue serves it. Greying it is the only warning a
-- player gets, so it comes with the reason attached.
function LootThresholdSpec:should_grey_the_uncommon_row_when_the_threshold_is_rare()
  local page = trash_open( ItemQuality.Rare )

  eq( row( page, "Uncommon" ).desaturated, true )
  eq( row( page, "Rare" ).desaturated, false )
end

function LootThresholdSpec:should_say_why_a_greyed_row_is_greyed()
  local page = trash_open( ItemQuality.Rare )
  local tooltip = row( page, "Uncommon" ).tooltip_text

  eq( tooltip[ 1 ], "Uncommon" )
  lu.assertStrContains( tooltip[ 2 ], "Uncommon items can't be master looted" )
  lu.assertStrContains( tooltip[ 2 ], "threshold is Rare" )
end

function LootThresholdSpec:should_grey_both_rows_when_the_threshold_is_epic()
  local page = trash_open( ItemQuality.Epic )

  eq( row( page, "Uncommon" ).desaturated, true )
  eq( row( page, "Rare" ).desaturated, true )
  lu.assertStrContains( row( page, "Rare" ).tooltip_text[ 2 ], "threshold is Epic" )
end

-- The threshold is the raid leader's setting and can change between visits, so it is read on
-- every draw rather than remembered.
function LootThresholdSpec:should_follow_the_threshold_changing_between_visits()
  local page = trash_open( ItemQuality.Epic )
  eq( row( page, "Uncommon" ).desaturated, true )

  u.loot_threshold( ItemQuality.Uncommon )
  page.show()

  eq( row( page, "Uncommon" ).desaturated, false )
  eq( row( page, "Uncommon" ).tooltip_text, nil )
end

-- Category rows have nothing to explain, so they must not pick up a tooltip meant for quality
-- rows.
function LootThresholdSpec:should_leave_category_rows_without_a_label_tooltip()
  local page = trash_open( ItemQuality.Epic )

  for _, name in ipairs( { "Marks", "Hearts", "Gems", "Trash", "Trash Ignored" } ) do
    eq( row( page, name ).tooltip_text, nil, name )
  end
end

-- A rotation with a queue per category, and nothing else: what a queue tab reads, and the one edit
-- a spec here makes through it. The rules about queues are AutoRoundRobin's, and what each control
-- and search does to one is AutoRoundRobinQueuesTabSpec's.
---@param queues table<string, string[]>
---@param categories string[]?
local function fake_round_robin( queues, categories )
  local rotation = { cycled = {} }

  rotation.get_categories = function() return categories or { "Marks", "Hearts", "Gems", "Trash" } end

  rotation.get_rows = function( category )
    local result = {}

    for i, name in ipairs( queues[ category ] or {} ) do
      table.insert( result, { name = name, class = "Warrior", core = false, position = i } )
    end

    return result
  end

  rotation.cycle = function( category, offset )
    table.insert( rotation.cycled, string.format( "%s:%d", category, offset ) )
  end

  return rotation
end

---@param count number
---@return string[]
local function players( count )
  local result = {}

  for i = 1, count do table.insert( result, "Player" .. i ) end

  return result
end

-- The page on a queue tab, Hearts/Marks unless told otherwise, over a rotation holding the given
-- queues.
---@param queues table<string, string[]>
---@param opts table? -- { deps, ctx, tab, categories }
local function queues_page( queues, opts )
  local o = opts or {}
  local rotation = fake_round_robin( queues, o.categories )

  local deps = o.deps or {}
  deps.round_robin = deps.round_robin or function() return rotation end

  local page = shown_page( o.ctx or mock_context(), deps )
  select_tab( page, o.tab or "Hearts/Marks" )

  return page, rotation
end

-- The column showing a queue right now.
---@return QueueColumnUnderTest
local function column( page, category )
  for _, candidate in pairs( page.get_queue_columns() ) do
    if candidate.category == category and candidate.frame.visible then return candidate end
  end

  error( string.format( "The %s queue is not on screen.", category ), 2 )
end

---@alias QueueColumnUnderTest { frame: table, search: table, clear: table, category: string }

---@return string[]
local function column_line_types( page, category )
  local result = {}

  for _, entry in ipairs( column( page, category ).frame.lines ) do table.insert( result, entry.line_type ) end

  return result
end

-- The players a queue shows, top to bottom, as the rows were handed them.
---@return string[]
local function queue_names( page, category )
  local result = {}

  for _, entry in ipairs( column( page, category ).frame.lines ) do
    if entry.line_type == "round_robin_row" then
      table.insert( result, u.decolorize( entry.frame.row.player ) or entry.frame.row.player )
    end
  end

  return result
end

---@return table
local function button( page, category, label )
  for _, entry in ipairs( column( page, category ).frame.lines ) do
    if entry.line_type == "button" and entry.frame.text == label then return entry.frame end
  end

  error( string.format( "There was no %q button under %s.", label, category ), 2 )
end

---@return number
local function visible_column_count( page )
  local result = 0

  for _, candidate in pairs( page.get_queue_columns() ) do
    if candidate.frame.visible then result = result + 1 end
  end

  return result
end

-- How tall a queue always is: the margin above its search box, the box, a full 20 rows, the gap
-- under them and its buttons.
local QUEUE_HEIGHT = 7 + 18 + 9 + 20 * (16 + 2) + 25 + (8 + 24 * 0.76)

-- A queue's frame: a 194 wide row with 20 of room either side.
local QUEUE_WIDTH = 194 + 20 * 2

-- Inside the panel's inset, split in two.
local PANEL_HALF = (CANVAS_WIDTH - 32 + 14 - 12 * 2) / 2

QueuesTabSpec = {}

-- Two queues a tab, side by side, in the order the tab's name says them.
function QueuesTabSpec:should_show_hearts_on_the_left_and_marks_on_the_right()
  local page = queues_page( { Hearts = { "Ann" }, Marks = { "Bob" } } )

  local left, right = column( page, "Hearts" ).frame, column( page, "Marks" ).frame

  eq( queue_names( page, "Hearts" ), { "Ann" } )
  eq( queue_names( page, "Marks" ), { "Bob" } )
  eq( left.anchor.relative_frame, page.get_panel() )
  eq( right.anchor.relative_frame, page.get_panel() )
  eq( left.anchor.x < right.anchor.x, true )
end

-- Each queue in the middle of its half, so the two sit the same distance from the line between
-- them, and -- give or take the odd pixel the panel's width leaves over -- from the panel's edges.
function QueuesTabSpec:should_centre_each_queue_in_its_half()
  local page = queues_page( { Hearts = { "Ann" }, Marks = { "Bob" } } )
  local left, right = column( page, "Hearts" ).frame, column( page, "Marks" ).frame
  local separator_x = page.get_separator().anchor.x

  eq( left.width, QUEUE_WIDTH )
  eq( right.width, QUEUE_WIDTH )
  eq( separator_x - (left.anchor.x + QUEUE_WIDTH), right.anchor.x - (separator_x + 1) )

  local left_edge = left.anchor.x - 12
  local right_edge = (12 + PANEL_HALF * 2) - (right.anchor.x + QUEUE_WIDTH)
  eq( math.abs( left_edge - right_edge ) <= 1, true )
end

-- On whole pixels, both queues and the separator_x. A queue on a fraction of one takes its thin scrollbar
-- with it, and the client draws the two bars a different width when they start partway into a
-- pixel by different amounts.
function QueuesTabSpec:should_put_the_queues_and_the_line_on_whole_pixels()
  for _, canvas_width in ipairs( { 665, 666, 667, 668 } ) do
    local ctx = mock_context()
    local canvas = u.modules().api.CreateFrame( "Frame" )
    canvas.GetWidth = function() return canvas_width end

    local rotation = fake_round_robin( { Hearts = { "Ann" }, Marks = { "Bob" } } )
    local page = OptionsPage.new( ctx, canvas, { round_robin = function() return rotation end } )
    page.show()
    select_tab( page, "Hearts/Marks" )

    local left, right = column( page, "Hearts" ).frame, column( page, "Marks" ).frame
    local separator_x = page.get_separator().anchor.x

    for _, x in ipairs( { left.anchor.x, right.anchor.x, separator_x } ) do
      eq( x, math.floor( x ), string.format( "canvas %d", canvas_width ) )
    end

    eq( separator_x - (left.anchor.x + QUEUE_WIDTH), right.anchor.x - (separator_x + 1), string.format( "canvas %d", canvas_width ) )
  end
end

-- Down the middle of the panel, as tall as the queues beside it.
function QueuesTabSpec:should_draw_a_line_between_the_two_queues()
  local page = queues_page( { Marks = { "Ann" } } )
  local separator = page.get_separator()

  eq( separator.visible, true )
  eq( separator.anchor.relative_frame, page.get_panel() )
  eq( separator.anchor.point, "TOPLEFT" )
  eq( separator.anchor.x, 12 + math.floor( PANEL_HALF ) )
  eq( separator.anchor.y, -12 )
  eq( separator.width, 1 )
  eq( separator.height, QUEUE_HEIGHT - 11 )
end

function QueuesTabSpec:should_hide_the_line_on_the_other_tabs()
  local page = queues_page( { Marks = { "Ann" } } )

  select_tab( page, "Loot" )

  eq( page.get_separator().visible, false )
end

function QueuesTabSpec:should_show_gems_and_trash_on_the_other_tab()
  local page = queues_page( { Gems = { "Cid" }, Trash = { "Dan" } }, { tab = "Gems/Trash" } )

  eq( queue_names( page, "Gems" ), { "Cid" } )
  eq( queue_names( page, "Trash" ), { "Dan" } )
  eq( visible_column_count( page ), 2 )
end

-- How many are queued, a row per player, and the buttons that edit the queue: what the queue
-- window used to be, less its title and its dropdown, which the tabs have taken over.
function QueuesTabSpec:should_lay_out_the_count_the_players_and_the_buttons()
  local page = queues_page( { Marks = { "Ann", "Bob" } } )

  eq( column_line_types( page, "Marks" ),
    { "round_robin_count", "round_robin_row", "round_robin_row", "button", "button", "button" } )
  eq( column( page, "Marks" ).frame.lines[ 1 ].frame.row.count, "2" )
end

-- Nothing on the panel itself: the queues are drawn into frames of their own, since each scrolls.
function QueuesTabSpec:should_leave_the_panel_to_the_queues()
  local page = queues_page( { Marks = { "Ann" } } )

  eq( #page.get_panel().lines, 0 )
end

function QueuesTabSpec:should_name_each_search_box_after_its_queue()
  local page = queues_page( { Marks = { "Ann" } } )

  eq( u.decolorize( column( page, "Hearts" ).search.text ), "Hearts" )
  eq( u.decolorize( column( page, "Marks" ).search.text ), "Marks" )
end

-- The first line sits under the box, so the box never covers the count or a row.
function QueuesTabSpec:should_start_each_queue_under_its_search_box()
  local page = queues_page( { Marks = { "Ann" } } )

  eq( column( page, "Marks" ).frame.lines[ 1 ].padding, 7 + 18 + 9 + 2 )
end

-- Held off the top of the panel, in line with the rows under it.
function QueuesTabSpec:should_hold_the_search_box_off_the_top()
  local page = queues_page( { Marks = { "Ann" } } )
  local marks = column( page, "Marks" )

  eq( marks.search.anchor.relative_frame, marks.frame )
  eq( marks.search.anchor.x, 20 )
  eq( marks.search.anchor.y, -7 )
end

function QueuesTabSpec:should_show_20_players_before_a_queue_scrolls()
  local page = queues_page( { Marks = players( 30 ) } )

  eq( #queue_names( page, "Marks" ), 20 )
  eq( column( page, "Marks" ).frame.get_scroll().total, 30 )
end

-- Each queue scrolls on its own.
function QueuesTabSpec:should_scroll_one_queue_without_moving_the_other()
  local page = queues_page( { Hearts = players( 30 ), Marks = players( 30 ) } )

  column( page, "Marks" ).frame:scroll_by( 3 )

  eq( queue_names( page, "Marks" )[ 1 ], "Player4" )
  eq( queue_names( page, "Hearts" )[ 1 ], "Player1" )
end

-- Every change to the box lists the queue again, and an emptied box lists everybody.
function QueuesTabSpec:should_list_the_queue_again_as_the_search_changes()
  local page = queues_page( { Marks = { "Ann", "Bob", "Dana" } } )
  local search = column( page, "Marks" ).search

  search.type( "a" )
  eq( queue_names( page, "Marks" ), { "Ann", "Dana" } )

  search.type( "an" )
  eq( queue_names( page, "Marks" ), { "Ann", "Dana" } )

  search.type( "ann" )
  eq( queue_names( page, "Marks" ), { "Ann" } )

  search.type( "" )
  eq( queue_names( page, "Marks" ), { "Ann", "Bob", "Dana" } )
end

function QueuesTabSpec:should_keep_each_queues_search_to_itself()
  local page = queues_page( { Hearts = { "Ann", "Bob" }, Marks = { "Ann", "Bob" } } )

  column( page, "Hearts" ).search.type( "bo" )

  eq( queue_names( page, "Hearts" ), { "Bob" } )
  eq( queue_names( page, "Marks" ), { "Ann", "Bob" } )
end

-- The other tab draws into the same two columns, so its boxes start empty, and coming back finds
-- the search where it was left.
function QueuesTabSpec:should_keep_a_search_while_another_tab_is_open()
  local page = queues_page( { Hearts = { "Ann", "Bob" }, Gems = { "Ann", "Bob" } } )

  column( page, "Hearts" ).search.type( "bo" )
  select_tab( page, "Gems/Trash" )

  eq( column( page, "Gems" ).search.value, "" )
  eq( queue_names( page, "Gems" ), { "Ann", "Bob" } )

  select_tab( page, "Hearts/Marks" )

  eq( column( page, "Hearts" ).search.value, "bo" )
  eq( queue_names( page, "Hearts" ), { "Bob" } )
end

-- Every keystroke redraws the page, and a box that was hidden or rewritten on the way would lose
-- the keyboard, or send the cursor to the end, under whoever is typing.
function QueuesTabSpec:should_leave_the_box_being_typed_into_alone()
  local page = queues_page( { Marks = { "Ann", "Bob" } } )
  local marks = column( page, "Marks" )
  local set_values = marks.search.set_value_count

  marks.search.type( "b" )
  marks.search.type( "bo" )

  eq( marks.search.set_value_count, set_values )
  eq( marks.frame.hide_count, 0 )
end

-- Whatever the list was scrolled to is not in the list a new search makes.
function QueuesTabSpec:should_send_a_queue_back_to_the_top_when_the_search_changes()
  local page = queues_page( { Marks = players( 30 ) } )
  local marks = column( page, "Marks" )

  marks.frame:scroll_by( 3 )
  marks.search.type( "player" )

  eq( marks.frame.get_scroll().offset, 0 )
end

-- The x beside a search box empties it, which lists everybody again like any other emptying would.
function QueuesTabSpec:should_clear_a_search_from_the_x_beside_it()
  local page = queues_page( { Hearts = { "Ann", "Bob" }, Marks = { "Ann", "Bob" } } )
  local hearts, marks = column( page, "Hearts" ), column( page, "Marks" )

  hearts.search.type( "bo" )
  marks.search.type( "an" )
  hearts.clear:OnClickCallback()

  eq( hearts.search.value, "" )
  eq( queue_names( page, "Hearts" ), { "Ann", "Bob" } )
  eq( queue_names( page, "Marks" ), { "Ann" } )
end

-- Only there while there is something to clear.
function QueuesTabSpec:should_show_the_x_only_while_there_is_a_search()
  local page = queues_page( { Marks = { "Ann" } } )
  local marks = column( page, "Marks" )

  eq( marks.clear.visible, false )

  marks.search.type( "a" )
  eq( marks.clear.visible, true )

  marks.clear:OnClickCallback()
  eq( marks.clear.visible, false )
end

-- The other tab draws into the same column, so the x follows whose search is in the box.
function QueuesTabSpec:should_show_the_x_for_the_search_in_the_box_now()
  local page = queues_page( { Hearts = { "Ann" }, Gems = { "Ann" } } )

  column( page, "Hearts" ).search.type( "a" )
  select_tab( page, "Gems/Trash" )

  eq( column( page, "Gems" ).clear.visible, false )

  select_tab( page, "Hearts/Marks" )

  eq( column( page, "Hearts" ).clear.visible, true )
end

function QueuesTabSpec:should_hide_the_queues_on_the_other_tabs()
  local page = queues_page( { Marks = { "Ann" } } )

  select_tab( page, "General" )

  eq( visible_column_count( page ), 0 )
end

function QueuesTabSpec:should_open_the_add_form_for_the_queue_it_is_under()
  local added_for
  local page = queues_page( { Marks = { "Ann" } }, { deps = { add_player = function( category ) added_for = category end } } )

  button( page, "Marks", "Add" ).OnClick()

  eq( added_for, "Marks" )
end

function QueuesTabSpec:should_cycle_the_queue_it_is_under()
  local page, rotation = queues_page( { Hearts = { "Ann", "Bob" } } )

  button( page, "Hearts", "Up" ).OnClick()
  button( page, "Hearts", "Down" ).OnClick()

  eq( rotation.cycled, { "Hearts:1", "Hearts:-1" } )
end

-- As tall as a full queue whatever is in it, so the page doesn't jump about as a search narrows
-- the list, and the buttons stay put. The panel holds the taller of the two, less the margin the
-- queue already keeps under its buttons.
function QueuesTabSpec:should_keep_room_for_a_full_queue()
  local page = queues_page( { Marks = { "Ann" } } )

  eq( column( page, "Hearts" ).frame.height, QUEUE_HEIGHT )
  eq( column( page, "Marks" ).frame.height, QUEUE_HEIGHT )
  eq( page.get_panel().height, 12 * 2 + QUEUE_HEIGHT - 11 )

  column( page, "Marks" ).search.type( "zed" )

  eq( page.get_panel().height, 12 * 2 + QUEUE_HEIGHT - 11 )
end

-- Both tabs scroll the same two columns, so a queue scrolled down must not open the one in its
-- place on the other tab scrolled down too. Switched while the page is closed, which is what the
-- slash commands do: nothing is drawn in between that could put the columns back at the top.
function QueuesTabSpec:should_open_each_tab_at_the_top()
  local page = queues_page( { Marks = players( 30 ), Trash = players( 30 ) } )
  column( page, "Marks" ).frame:scroll_by( 3 )
  page.get_frame().visible = false

  page.select_tab( "Gems/Trash" )
  page.show()

  eq( queue_names( page, "Trash" )[ 1 ], "Player1" )
end

-- A queue the rotation doesn't have is left off rather than drawn empty.
function QueuesTabSpec:should_leave_out_a_queue_the_rotation_does_not_have()
  local page = queues_page( { Gems = { "Ann" } }, { tab = "Gems/Trash", categories = { "Gems" } } )

  eq( visible_column_count( page ), 1 )
  eq( queue_names( page, "Gems" ), { "Ann" } )
end

-- Nobody opens the settings window before on_ready, but a page asked to draw the tab then has
-- nothing to draw rather than something to fail on.
function QueuesTabSpec:should_draw_nothing_before_the_rotation_is_built()
  local page = queues_page( {}, { deps = { round_robin = function() return nil end } } )

  eq( visible_column_count( page ), 0 )
end

-- The rotation calls refresh whenever a queue moves, which is when the tab is out of date.
function QueuesTabSpec:should_redraw_on_refresh_while_on_screen()
  local queues = { Marks = { "Ann" } }
  local page = queues_page( queues )

  table.insert( queues.Marks, "Bob" )
  page.refresh()

  eq( queue_names( page, "Marks" ), { "Ann", "Bob" } )
end

-- A page that isn't on screen has nothing to correct, and showing it reads everything afresh.
function QueuesTabSpec:should_not_redraw_on_refresh_while_hidden()
  local queues = { Marks = { "Ann" } }
  local page = queues_page( queues )

  page.get_frame().visible = false
  table.insert( queues.Marks, "Bob" )
  page.refresh()

  eq( queue_names( page, "Marks" ), { "Ann" } )
end

-- The open tab's content is boxed in under the tabs, so it is plain which tab it belongs to.
PanelSpec = {}

function PanelSpec:should_put_the_tab_contents_in_the_bordered_panel()
  local page = shown_page( mock_context() )

  eq( #page.get_panel().lines, 4 )
  eq( page.get_panel().backdrop.edgeFile, "Interface\\Tooltips\\UI-Tooltip-Border" )
end

function PanelSpec:should_hang_the_panel_under_the_tabs()
  local page = shown_page( mock_context() )
  local anchor = page.get_panel().anchor

  eq( anchor.relative_frame, line( page, "tabs" ) )
  eq( anchor.point, "TOPLEFT" )
  eq( anchor.relative_point, "BOTTOMLEFT" )
end

-- Across the page rather than as wide as its widest setting, reaching further left than the
-- summary, with the first tab held in from the panel's corner.
function PanelSpec:should_span_the_page()
  local page = shown_page( mock_context() )
  local panel = page.get_panel()

  eq( panel.anchor.x, -8 )
  eq( panel.width, CANVAS_WIDTH - 32 + 14 )
end

-- Room above the first line and below the last, whichever tab is open.
function PanelSpec:should_fit_its_lines()
  local page = shown_page( mock_context() )

  eq( page.get_panel().height, 12 + 20 + 5 + 20 + 5 + 20 + 5 + 20 + 12 )

  select_tab( page, "Loot" )
  local count = #rows( page )

  eq( page.get_panel().height, 12 + count * 14 + (count - 1) * 2 + 12 )
end

-- The list scrolls once it outgrows the panel; the settings never do. Leaving the Loot tab says
-- so, or its scrollbar would follow the settings.
function PanelSpec:should_only_scroll_the_loot_tab()
  local page = shown_page( mock_context() )
  select_tab( page, "Loot" )

  eq( page.get_panel().get_scroll().total, #rows( page ) )

  select_tab( page, "General" )

  eq( page.get_panel().get_scroll().total, 0 )
end

ExtensionSwitchSpec = {}

-- No Enabled switch, because "Auto round robin" is already it: two switches for one question
-- could disagree, and Auto round robin ticked on a disabled extension reads as broken. The
-- addon declares hide_enabled_option, so core draws none either and keeps the extension on --
-- which is what makes leaving it off this page safe rather than a way to strand somebody.
function ExtensionSwitchSpec:should_not_draw_an_enabled_switch()
  local page = shown_page( mock_context() )

  for _, entry in ipairs( all_lines( page ) ) do
    eq( entry.frame.text ~= "Enabled", true, "The page still draws an Enabled switch." )
  end
end

-- It never asks core either. A page that read is_enabled would be showing a value nothing can
-- change, and one that wrote it would be writing something core refuses.
function ExtensionSwitchSpec:should_not_touch_cores_enabled_state()
  local ctx = mock_context()
  shown_page( ctx )

  eq( ctx.state.set_to, nil )
end

SettingsSpec = {}

-- Registered through ctx.config during on_enable, so they live in core's config -- but
-- core's own page renders an explicit list of its own settings and nothing else, which is
-- why this page is where they are visible at all.
function SettingsSpec:should_draw_its_own_settings_from_the_config()
  local page = shown_page( mock_context() )

  eq( checkbox( page, "Auto round robin" ).checked, true )
  eq( checkbox( page, "Announce awards" ).checked, true )
  eq( checkbox( page, "Announce drops the rotation will hand out" ).checked, false )
  eq( checkbox( page, "Remove non-core players from queues on new group" ).checked, true )
end

function SettingsSpec:should_turn_off_removing_non_core_players_from_its_checkbox()
  local ctx = mock_context()
  local page = shown_page( ctx )

  checkbox( page, "Remove non-core players from queues on new group" ).on_click( false )

  eq( ctx.state.settings.auto_round_robin_new_group_reset, false )
end

function SettingsSpec:should_write_a_setting_back_when_its_checkbox_is_clicked()
  local ctx = mock_context()
  local page = shown_page( ctx )

  checkbox( page, "Announce drops the rotation will hand out" ).on_click( true )

  eq( ctx.state.settings.auto_round_robin_announce_drops, true )
end

-- Rebuilt from scratch on every visit: all of these can be changed from a slash command,
-- or by another page, between one viewing and the next.
function SettingsSpec:should_reread_every_setting_when_the_page_is_shown_again()
  local ctx = mock_context()
  local page = shown_page( ctx )

  ctx.state.settings.auto_round_robin = false
  page.show()

  eq( checkbox( page, "Auto round robin" ).checked, false )
end

os.exit( lu.LuaUnit.run() )
