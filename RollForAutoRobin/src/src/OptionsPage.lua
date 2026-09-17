RollForAutoRobin = RollForAutoRobin or {}
local ar = RollForAutoRobin

if ar.OptionsPage then return end

local hl = RollFor.colors.hl
local white = RollFor.colors.white

local M = {}

-- Core's shared helpers. RollFor is guaranteed to be loaded: the TOC declares it as a
-- dependency, so the client refuses to load this addon without it.
local m = RollFor

-- This addon's page in RollFor's options window.
--
-- RollFor creates the canvas and registers it with the game's settings panel, then hands it
-- over and asks this to fill it in. Core does not know what is on the page and does not want
-- to: an extension keeps its own database, so it is the only thing that knows what is worth
-- showing. What core does supply is the builders -- the popup builder, the frame builder and
-- the widget set -- so a page can be assembled out of the same pieces RollFor's own page uses
-- rather than out of raw CreateFrame calls.
--
-- The settings on the General tab are this addon's own, registered through ctx.config during
-- on_enable. They live in core's toggles table, so they already answer to /rf config -- but
-- core's own page renders an explicit list of its own settings and nothing else, so this page is
-- where they are actually visible.
--
-- The Loot tab is which items the rotation hands out: the selection tree over the round-robin
-- catalogue, drawn straight onto the page. It used to be a window of its own, and
-- /rf autorobin loot opens this tab now.
--
-- The queue tabs are the queues themselves, two to a tab side by side, each with a search box and
-- the controls that edit it (see AutoRoundRobinQueuesTab). That used to be a window with a
-- category dropdown, and /rf autorobin followed by a queue's name opens that queue's tab now.

-- A command and the words it takes, the way RollFor writes one: the command and each word
-- highlighted, the brackets and the bars between the words white, so the words stand out as the
-- part to type. The bars are doubled, since a single one starts an escape sequence in the client.
---@param command string
---@param choices string[]
---@return string
local function command_choices( command, choices )
  local words = {}

  for _, choice in ipairs( choices ) do table.insert( words, hl( choice ) ) end

  return string.format( "%s %s%s%s", hl( command ), white( "[" ), table.concat( words, white( "||" ) ), white( "]" ) )
end

-- What this addon is for, in its own words. Core does not hold a copy: it has no use for one,
-- since this page is the only thing that shows it.
local SUMMARY = string.format(
  "Hands selected items out in a strict rotation instead of rolling for them.\n" ..
  "One queue per category, each independent -- taking a gem does not move you down the Marks queue.\n" ..
  "The first player in the queue who can actually receive gets the item, and goes to the back.\n" ..
  "Open the list with %s, and a queue with %s.",
  hl( "/rf autorobin loot" ), command_choices( "/rf autorobin", { "hearts", "marks", "gems", "trash" } )
)

local SIDE_INSET, TOP_INSET = 16, 16

-- Vertical gap above each kind of line. Mirrors what RollFor uses on its own page so the two
-- look like one addon; nothing enforces that, and nothing has to. The queue tabs' lines carry
-- their own, from the transformer that lays them out.
local paddings = {
  section_header = 13,
  paragraph = 9,
  checkbox = 5,
  -- Tight, the same as RollForAutoLoot's list, so the two lists look alike.
  tree_node = 2
}

-- Prose is followed by a bigger gap than the one between two controls, so the tabs
-- underneath read as a new thought rather than the summary's last line.
local after_paragraph_padding = 16

-- The open tab's content sits in a bordered panel under the tabs, the way a tabbed window
-- draws one, so it is plain which tab the settings belong to. Same border as RollForAutoLoot's
-- page, so the addons draw a box the same way.
local panel_backdrop = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true,
  tileSize = 16,
  edgeSize = 16,
  insets = { left = 3, right = 3, top = 3, bottom = 3 }
}

-- Room between the panel's border and what is inside it, on every side.
local PANEL_INSET = 12

-- How far the panel reaches out to the left of the summary, towards the edge of the page.
local PANEL_OUTDENT = 14

-- How far in from the panel's left edge the first tab sits, which keeps it off the rounded corner.
local TABS_INDENT = 8

-- How far a line sits to the right of the summary. The tabs follow the panel out to the left.
local indents = {
  tabs = TABS_INDENT - PANEL_OUTDENT
}

-- The catalogue fits on the page with every category open today, but nothing stops it growing.
-- Past this many rows the mouse wheel brings the rest into view.
local VISIBLE_ROWS = 27

-- Room between the scrollbar and the panel's right edge, clear of the border.
local SCROLLBAR_INSET = 8

-- How far the panel reaches up under the tabs. The open tab's artwork hangs a few pixels below
-- the row, and it is drawn over the panel, so it covers the border's top edge beneath it and
-- reads as joined to the panel rather than resting on it.
local PANEL_TAB_OVERLAP = 2

-- Room a queue keeps under its rows for a row of buttons, which the popup lays out along its own
-- bottom edge rather than under the line above: the 8 it holds them off the edge by, and a 24 high
-- button at the 0.76 every button is drawn at.
local BUTTON_ROW_HEIGHT = 8 + 24 * 0.76

-- How many players a queue shows before it scrolls. Most of a raid, so scrolling is for the last
-- few and for a queue carrying players from raids gone by, and searching is the quick way to any
-- one of them.
local QUEUE_ROWS = 20

-- A row and the gap the transformer puts above it.
local QUEUE_ROW_PITCH = ar.RoundRobinWidgets.ROW_HEIGHT + 2

-- Between the last row a queue has room for and its buttons, which also covers the sliver the
-- count line takes.
local QUEUE_BUTTON_GAP = 25

-- Above a queue's search box, holding it off the top of the panel.
local QUEUE_TOP_MARGIN = 7

-- How far short of a queue's bottom the panel stops. The popup already holds a queue's buttons off
-- its bottom edge, so the panel's full inset under that would be two margins stacked.
local QUEUE_PANEL_TRIM = 11

-- Room either side of a queue's rows, the same on both so the rows sit in the middle of the
-- queue's frame, and its buttons -- which the popup centres -- under them. The queue's own
-- scrollbar goes in the room on the right, this far in from the edge.
local QUEUE_SIDE_ROOM = 20
local QUEUE_SCROLLBAR_INSET = 4

-- A queue's frame: its rows and the room either side.
local QUEUE_WIDTH = ar.RoundRobinWidgets.ROW_WIDTH + QUEUE_SIDE_ROOM * 2

-- The line down the middle of a queue tab, between its two queues. The panel border's grey, a
-- little fainter, since it divides what the border already holds together.
local SEPARATOR_WIDTH = 1
local SEPARATOR_COLOR = { 0.4, 0.4, 0.4, 0.6 }

-- The search box's typing area. The box is labelled with its queue's name and has its clear button
-- after it, so the whole thing stays inside the width of a row, clear of the count at the row's
-- right edge.
local SEARCH_FIELD_WIDTH = 85

-- The x that empties a search box: the client's own close button, the same one a queue row removes
-- a player with, a couple of pixels bigger so it reads as belonging to the box beside it rather
-- than to a row. The template is 32 square, scaled to the size it is drawn at on screen.
local CLEAR_BUTTON_TEMPLATE = "UIPanelCloseButtonNoScripts"
local CLEAR_BUTTON_SIZE = 32 * 0.55 + 2
local CLEAR_BUTTON_SCALE = CLEAR_BUTTON_SIZE / 32

-- Where the x sits from the search box's right edge, on screen. The box's frame ends 8 past the
-- typing area (see RoundRobinWidgets.text_field), so this takes that back and puts the x against
-- the box, a pixel below the box's middle.
local CLEAR_BUTTON_X = -8
local CLEAR_BUTTON_Y = -1

-- A search is a part of a name, and a name is at most 12 letters.
local SEARCH_MAX_LETTERS = 12

-- Between the search box and the first line under it.
local SEARCH_GAP = 9

-- The same size every other RollFor window draws its buttons at.
local button_defaults = {
  width = 80,
  height = 24,
  scale = 0.76
}

-- The settings this page draws, in the order they read: the feature, then what it says out
-- loud. Each one is a key in core's config, which is where register_toggle put it.
--
-- There is no Enabled switch above them. Core only injects one onto the page it draws for an
-- extension that supplies none of its own, so a page like this one would have to carry its own
-- -- and this addon declares hide_enabled_option instead, because the first setting below is
-- already that switch.
local TOGGLES = {
  { key = "auto_round_robin", label = "Auto round robin" },
  { key = "auto_round_robin_announce", label = "Announce awards" },
  { key = "auto_round_robin_announce_drops", label = "Announce drops the rotation will hand out" },
  { key = "auto_round_robin_new_group_reset", label = "Remove non-core players from queues on new group" }
}

-- The queue tabs, and the two queues each shows, left then right. The names are the catalogue's
-- categories (see AutoRoundRobinDb); one the rotation doesn't have is left out rather than drawn
-- empty.
local QUEUE_TABS = {
  { label = "Hearts/Marks", categories = { "Hearts", "Marks" } },
  { label = "Gems/Trash", categories = { "Gems", "Trash" } }
}

-- Everything under the summary is split into tabs, in the order they are drawn. The summary
-- stays above them: it says what the addon is for, which is true whichever tab is open.
local TABS = { "General", "Loot", QUEUE_TABS[ 1 ].label, QUEUE_TABS[ 2 ].label }

---@class AutoRobinOptionsPage
---@field show fun()
---@field refresh fun() -- redraws the page if it is on screen, for something that changed under it
---@field select_tab fun( label: string )
---@field get_frame fun(): table?
---@field get_panel fun(): table?
---@field get_queue_columns fun(): table<number, AutoRobinQueueColumn>
---@field get_separator fun(): table? -- the line between a queue tab's two queues

-- One side of a queue tab: a scrolling frame of its own for the queue's lines, and the search box
-- above them. Each tab draws its two queues into the same two columns.
---@class AutoRobinQueueColumn
---@field frame table
---@field search table -- a text_field
---@field clear table -- the button that empties the search box
---@field category string? -- whose queue it drew last

-- What the page needs from the rest of the addon. Getters rather than the things themselves,
-- because core builds the page before on_ready builds the rotation.
---@class AutoRobinOptionsPageDeps
---@field on_selection_changed fun()? -- a Loot tab row was ticked
---@field round_robin (fun(): AutoRoundRobin?)? -- nil until on_ready
---@field add_player (fun( category: string ))? -- opens the form that puts somebody into a queue

---@param ctx ExtensionContext
---@param parent table -- the canvas RollFor registered for this page
---@param deps AutoRobinOptionsPageDeps?
---@return AutoRobinOptionsPage
function M.new( ctx, parent, deps )
  deps = deps or {}

  local popup, panel

  -- Forward declared: the panel redraws the page when it is scrolled, and rows redraw it when
  -- they are clicked.
  local show

  -- Which tab is open. Kept for as long as the page exists rather than reset on every visit,
  -- so leaving the settings window and coming back finds it where it was.
  local selected_tab = 1

  -- The summary is written a line per thought, so letting it wrap turns a list into prose:
  -- the continuation of a long line sits under the start of it and reads as another entry.
  -- Give it the width of the canvas it is actually in rather than the widget's own default,
  -- which is sized for a narrower page than the settings window.
  --
  -- Measured at show() rather than at build, because the settings window sizes the canvas
  -- when it displays the page. Falls back to whatever the widget chose if it is asked before
  -- then.
  local function paragraph_width( frame )
    local available = (parent.GetWidth and parent:GetWidth() or 0) - SIDE_INSET * 2

    return available > 0 and math.max( available, frame:GetWidth() or 0 ) or nil
  end

  local function create_popup()
    return ctx.popup_builder()
        :name( "RollForAutoRobinOptionsPage" )
        :parent( parent )
        :point( {
          point = "TOPLEFT",
          relative_frame = parent,
          relative_point = "TOPLEFT",
          x = SIDE_INSET,
          y = -TOP_INSET
        } )
        :gui_elements( ctx.gui_elements )
        :backdrop_color( 0, 0, 0, 0 )
        :no_border()
        :build()
  end

  -- Positioned under the tabs on every show rather than here, since that is when the tabs line
  -- exists to anchor it to.
  --
  -- The border is set on the frame rather than through the builder, whose borders follow the
  -- user's frame style: neither a hairline nor a dialog box looks like a group of settings.
  -- Typed as a plain table because Popup doesn't declare the backdrop methods every popup has.
  --
  -- Only the Loot tab's rows scroll; each queue scrolls in a frame of its own. Scrolling is just
  -- another reason to redraw, so it goes through the same show() everything else does.
  local function create_panel()
    local result = ctx.popup_builder()
        :name( "RollForAutoRobinOptionsPagePanel" )
        :parent( parent )
        :gui_elements( ctx.gui_elements )
        :scrollable( { line_types = "tree_node", max_lines = VISIBLE_ROWS, right_inset = SCROLLBAR_INSET } )
        :on_scroll( function() show() end )
        :build() --[[@as table]]

    result:SetBackdrop( panel_backdrop )
    result:SetBackdropColor( 0, 0, 0, 0.3 )
    result:SetBackdropBorderColor( 0.4, 0.4, 0.4, 1 )

    return result
  end

  -- Chains each line under the one before it, left-aligned apart from its indent. The first line
  -- sits `inset` in from the frame's top-left corner.
  ---@param frame table -- the popup the line goes into
  ---@param inset number
  ---@param line_type string
  ---@param previous_type string?
  ---@param configure fun( frame: table )
  ---@return table? -- the line; nil when it was scrolled out of view
  local function add_line( frame, inset, line_type, previous_type, configure )
    local padding = previous_type == nil and inset
        or previous_type == "paragraph" and after_paragraph_padding
        or paddings[ line_type ] or 5

    return frame.add_line( line_type, function( _, line_frame, lines )
      configure( line_frame )

      local count = #lines
      local indent = indents[ line_type ] or 0
      line_frame:ClearAllPoints()

      if count == 0 then
        line_frame:SetPoint( "TOPLEFT", frame, "TOPLEFT", inset + indent, -padding )
      else
        local previous_indent = indents[ lines[ count ].line_type ] or 0
        line_frame:SetPoint( "TOPLEFT", lines[ count ].frame, "BOTTOMLEFT", indent - previous_indent, -padding )
      end
    end, padding )
  end

  local function add_page_line( line_type, previous_type, configure )
    return add_line( popup, 0, line_type, previous_type, configure )
  end

  -- What went into the panel on this pass, which is what its height is measured from.
  local panel_lines = {}

  -- A line scrolled out of the panel is never drawn, and comes back as nil.
  local function add_panel_line( line_type, previous_type, configure )
    local line = add_line( panel, PANEL_INSET, line_type, previous_type, configure )
    if line then table.insert( panel_lines, line ) end
  end

  -- From just left of the summary to the page's right margin. Nil until the settings window has
  -- sized the canvas.
  ---@return number?
  local function panel_width()
    local width = (parent.GetWidth and parent:GetWidth() or 0) - SIDE_INSET * 2

    return width > 0 and width + PANEL_OUTDENT or nil
  end

  -- Hangs the panel under the tabs, across the page, and as tall as what is in it. The popup sizes
  -- itself to its lines as they are added, but to its own margins; the panel wants the same inset
  -- below its last line as above its first, and the page's width rather than the width of its
  -- widest line.
  ---@param tabs table -- the tabs line's frame
  ---@param content_height number? -- for a tab that draws into frames of its own rather than lines
  local function fit_panel( tabs, content_height )
    panel:ClearAllPoints()
    panel:SetPoint( "TOPLEFT", tabs, "BOTTOMLEFT", -TABS_INDENT, PANEL_TAB_OVERLAP )

    local width = panel_width()
    if width then panel:SetWidth( width ) end

    if content_height then
      panel:SetHeight( PANEL_INSET * 2 + content_height )
      return
    end

    local height = PANEL_INSET

    for _, line in ipairs( panel_lines ) do
      height = height + line.padding + line.frame:GetHeight()
    end

    panel:SetHeight( height )
  end

  -- No Enabled switch. This addon declares hide_enabled_option, because "Auto round robin" below
  -- is the same question -- and core keeps the extension on, so there would be nothing for a
  -- switch to say.
  local function add_general_tab()
    -- Nothing here scrolls. Told so, or the scrollbar the Loot tab left behind would stay up.
    panel:set_scroll_total( 0 )

    local previous

    for _, toggle in ipairs( TOGGLES ) do
      add_panel_line( "checkbox", previous, function( frame )
        frame:SetText( toggle.label )
        frame:SetChecked( ctx.config[ toggle.key ]() and true or false )
        frame.on_click = function( value ) ctx.config[ "set_" .. toggle.key ]( value ) end
      end )

      previous = "checkbox"
    end
  end

  -- Which rows of the list are closed, so the list opens the way it was left, reload or not.
  --
  -- The closed ones rather than the open ones, because everything starts open: an empty set is a
  -- list somebody has never touched, and a category the catalogue gains later arrives open too,
  -- with no first-time flag or seeding either way.
  --
  -- A db of its own rather than an `expanded` beside each entry's `enabled` in the selection db.
  -- That db is what the rotation reads to decide what to hand out; which rows are open is only
  -- how the list looks, and throwing it away only resets the look.
  --
  -- Keyed by the row's path, its name and its parents' names joined by PATH_SEPARATOR. Only
  -- categories open today, so a path is a category name, but a name alone would not be unique
  -- the moment one repeated under two parents.
  local PATH_SEPARATOR = "\31"

  ---@return table<string, boolean>
  local function collapsed()
    local store = ctx.db( "loot_tab" )
    store.collapsed = store.collapsed or {}

    return store.collapsed
  end

  -- Built the first time the Loot tab is drawn rather than with the page: core builds the page
  -- before on_ready, which is what migrates and seeds the db the tree is read from. Kept after
  -- that, because which rows are expanded is written on the tree's own nodes.
  local roots

  ---@type table<TreeNode, string>
  local paths = {}

  -- Opens every row that isn't in the closed set, and remembers each row's path for the click that
  -- closes it. Paths nothing in the tree has any more are dropped on the way: a category taken
  -- out of the catalogue has no row left to open.
  local function restore_expanded()
    local closed = collapsed()
    local seen = {}

    ---@param nodes TreeNode[]
    ---@param parent_path string?
    local function visit( nodes, parent_path )
      for _, node in ipairs( nodes ) do
        if node.children then
          local path = parent_path and (parent_path .. PATH_SEPARATOR .. node.data.name) or node.data.name

          paths[ node ] = path
          seen[ path ] = true
          node.data.expanded = not closed[ path ]

          visit( node.children, path )
        end
      end
    end

    visit( roots )

    for path in pairs( closed ) do
      if not seen[ path ] then closed[ path ] = nil end
    end
  end

  local function tree_roots()
    if not roots then
      roots = ctx.selection_tree.build_flat( ctx.db( "db" ) )
      restore_expanded()
    end

    return roots
  end

  -- The Trash category's rows name a quality (see AutoRoundRobinDb), and a quality below the
  -- master loot threshold can't be handed out at all -- GiveMasterLoot refuses it, so the award
  -- pass drops it before asking which queue serves it. Ticking such a row does nothing, which is
  -- worth saying out loud rather than leaving as a checkbox that quietly lies.
  --
  -- Read on every draw, not baked into the tree: the threshold is the raid leader's setting and
  -- can change between one visit and the next.
  ---@param data table -- a row's payload
  ---@return string[]? -- title first, body after; nil when the row can act
  local function threshold_warning( data )
    local quality = data.quality
    if not quality then return end

    local threshold = m.api.GetLootThreshold() or 0
    if quality >= threshold then return end

    -- States what's wrong rather than what's required: "%s or lower" reads as nonsense on the
    -- Uncommon row, which is already the lowest threshold the client offers.
    return {
      data.name,
      string.format( "%s items can't be master looted while the loot threshold is %s.",
        ar.AutoRoundRobinDb.quality_name( quality ), ar.AutoRoundRobinDb.quality_name( threshold ) )
    }
  end

  -- One row of the list, drawn the way core's selection tree window draws one: an item is its
  -- link, anything else a coloured label. What is checked, greyed out or expandable the tree has
  -- already decided -- apart from the loot threshold, which the tree knows nothing about.
  ---@param frame table -- a tree_node widget
  ---@param row SelectionTreeVisibleRow
  local function configure_row( frame, row )
    local data = row.data
    local warning = threshold_warning( data )

    frame:SetDepth( row.depth )
    frame:SetExpandable( row.expandable, row.expanded )
    frame:SetChecked( row.checked )
    frame:SetDesaturated( row.desaturated or warning ~= nil )

    frame.on_click = function()
      if not row.expandable then return end

      data.expanded = not data.expanded
      collapsed()[ paths[ row.node ] ] = not data.expanded or nil
      show()
    end

    -- Told after the write and the redraw, so anyone listening sees the selection it landed on
    -- rather than the one it was leaving.
    frame.on_check = function( checked )
      ctx.selection_tree.set_checked( row.node, checked )
      show()

      if deps.on_selection_changed then deps.on_selection_changed() end
    end

    if data.item then
      local link = m.ItemUtils.make_link( data.id, data.item.quality, data.item.name )

      frame:SetItem( {
        link = link,
        texture = data.item.icon,
        hover_background_color = data.hover_background_color,
        tooltip_position = data.tooltip_position
      }, m.ItemUtils.get_tooltip_link( link ) )
    else
      frame:SetText( data.name or "" )
      frame:SetLabelStyle( data.color, data.hover_text_color, data.hover_background_color )
      -- Set on every label, nil included: rows are reused, so a warning left on one would follow
      -- it onto whatever it draws next.
      frame:SetLabelTooltip( warning )
    end
  end

  local function add_loot_tab()
    local rows = ctx.selection_tree.visible_rows( tree_roots() )

    -- The whole list, not just what fits: the panel needs the real length to place the window
    -- and size the scrollbar. Told before the offset is read, since a list that just got shorter
    -- pulls the window back up.
    panel:set_scroll_total( #rows )

    -- The first row on screen sits the panel's inset below its top, whichever row that is.
    local first_visible = panel.get_scroll().offset + 1

    for index, row in ipairs( rows ) do
      add_panel_line( "tree_node", index > first_visible and "tree_node" or nil, function( frame )
        configure_row( frame, row )
      end )
    end
  end

  -- Draws one of a queue's lines. The same calls the queue window used to make on the same widgets,
  -- since these are the lines it was made of.
  ---@param frame table
  ---@param v table -- a line, as AutoRoundRobinQueuesContentTransformer lays it out
  local function draw_queue_line( frame, v )
    if v.type == "button" then
      frame:SetWidth( v.width or button_defaults.width )
      frame:SetHeight( v.height or button_defaults.height )
      frame:SetText( v.label or "" )
      frame:ClearAllPoints() -- This fixes a strange visual bug in BCC. Frame is either without label or misaligned without this.
      frame:SetScale( v.scale or button_defaults.scale )
      frame:SetScript( "OnClick", v.on_click or function() end )
    elseif v.type == "round_robin_row" then
      frame:SetHeader( false )
      frame:SetRow( v )
    elseif v.type == "round_robin_count" then
      frame:SetRow( v )
    elseif v.type == "text" then
      frame:SetText( v.value )
    end
  end

  local queues_transformer = ar.AutoRoundRobinQueuesContentTransformer.new()

  -- Built the first time a queue tab is drawn, for the same reason the tree is: the rotation it
  -- reads does not exist until on_ready. Kept after that; it holds nothing a redraw could stale.
  ---@type AutoRoundRobinQueuesTab?
  local queues

  -- What is typed into each queue's search box, by category. Kept for as long as the page exists,
  -- like the open tab, but not written down: a search is for finding somebody now.
  ---@type table<string, string>
  local searches = {}

  -- Left and right, built the first time a queue tab needs them and shared by every queue tab. Only
  -- ever walked with pairs: a queue the rotation doesn't have leaves its side unbuilt.
  ---@type table<number, AutoRobinQueueColumn>
  local columns = {}

  -- Which columns this pass drew into. The rest are hidden once it is done, rather than all of them
  -- before it starts: hiding a column hides its search box, which takes the keyboard away from
  -- whoever is typing into it, and every keystroke redraws the page.
  ---@type table<AutoRobinQueueColumn, boolean>
  local drawn_columns = {}

  -- Built the first time a queue tab is drawn, and hidden while any other tab is open.
  local separator
  local separator_drawn = false

  ---@param x number -- where the line's left edge sits, from the panel's left edge
  ---@param height number
  local function draw_separator( x, height )
    if not separator then
      separator = panel:CreateTexture( nil, "ARTWORK" )
      separator:SetTexture( "Interface\\Buttons\\WHITE8x8" )
      separator:SetVertexColor( unpack( SEPARATOR_COLOR ) )
    end

    separator:ClearAllPoints()
    -- By its left edge, not its middle: a 1 wide line centred on a whole pixel straddles two.
    separator:SetPoint( "TOPLEFT", panel, "TOPLEFT", x, -PANEL_INSET )
    separator:SetWidth( SEPARATOR_WIDTH )
    separator:SetHeight( height )
    separator:Show()

    separator_drawn = true
  end

  -- A queue's frame is a popup of its own because each queue scrolls on its own, and a popup has
  -- one viewport. Its search box is not one of its lines, for the reason drawn_columns gives:
  -- every redraw clears the lines, and clearing hides them.
  ---@param index number
  ---@return AutoRobinQueueColumn
  local function queue_column( index )
    if columns[ index ] then return columns[ index ] end

    local frame = ctx.popup_builder()
        :name( "RollForAutoRobinOptionsPageQueue" .. index )
        :parent( panel )
        :gui_elements( ctx.gui_elements )
        :backdrop_color( 0, 0, 0, 0 )
        :no_border()
        :scrollable( { line_types = "round_robin_row", max_lines = QUEUE_ROWS, right_inset = QUEUE_SCROLLBAR_INSET } )
        :on_scroll( function() show() end )
        :build() --[[@as table]]

    local search = ctx.gui_elements.text_field( frame )
    search:SetFieldWidth( SEARCH_FIELD_WIDTH )
    search:SetMaxLetters( SEARCH_MAX_LETTERS )
    search:ClearAllPoints()
    search:SetPoint( "TOPLEFT", frame, "TOPLEFT", QUEUE_SIDE_ROOM, -QUEUE_TOP_MARGIN )

    -- Built once alongside the box, for the same reason the box is. Emptying the box is all it
    -- does: that is a change like any other, and the box's own handler takes it from there.
    local clear = m.api.CreateFrame( "Button", nil, frame, CLEAR_BUTTON_TEMPLATE )
    clear:SetScale( CLEAR_BUTTON_SCALE )
    -- The offset is in the button's own scaled units, so it is divided back out by the scale.
    clear:SetPoint( "LEFT", search, "RIGHT", CLEAR_BUTTON_X / CLEAR_BUTTON_SCALE, CLEAR_BUTTON_Y / CLEAR_BUTTON_SCALE )
    clear:SetScript( "OnClick", function() search:SetValue( "" ) end )
    clear:Hide()

    columns[ index ] = { frame = frame, search = search, clear = clear }

    return columns[ index ]
  end

  -- Points the column's search box at this category's search. The handler goes first: putting the
  -- text in fires it, and the handler left over from another tab would file the text under that
  -- tab's queue. Only written when it differs, so the box isn't rewritten -- and its cursor sent to
  -- the end -- under somebody typing into it.
  ---@param column AutoRobinQueueColumn
  ---@param category string
  local function wire_search( column, category )
    local search = column.search

    search:SetText( ar.AutoRoundRobinDb.colorize( category ) )

    -- Every change redraws the list, and an emptied box lists everybody again. The list goes back
    -- to its top, since whatever it was scrolled to is not in the new list.
    search.on_change = function( text )
      if text == (searches[ category ] or "") then return end

      searches[ category ] = text
      column.frame:set_scroll_total( 0 )
      show()
    end

    local text = searches[ category ] or ""
    if search:GetValue() ~= text then search:SetValue( text ) end

    -- Nothing to clear in an empty box.
    if text == "" then column.clear:Hide() else column.clear:Show() end
  end

  -- Always as tall as a full queue, so the page doesn't jump about as a search narrows the list
  -- and the buttons stay where they were.
  ---@param column AutoRobinQueueColumn
  ---@return number
  local function queue_column_height( column )
    return QUEUE_TOP_MARGIN + column.search:GetHeight() + SEARCH_GAP + QUEUE_ROWS * QUEUE_ROW_PITCH
        + QUEUE_BUTTON_GAP + BUTTON_ROW_HEIGHT
  end

  ---@param content AutoRoundRobinQueuesTab
  ---@param index number -- 1 on the left, 2 on the right
  ---@param category string
  ---@param x number -- where the queue's frame starts, from the panel's left edge
  ---@return number -- how tall it is
  local function add_queue_column( content, index, category, x )
    local column = queue_column( index )
    local frame = column.frame

    column.category = category
    drawn_columns[ column ] = true

    frame:clear()
    wire_search( column, category )

    local lines = queues_transformer.transform( content.content( category, searches[ category ] ) )
    local row_count = 0

    for _, v in ipairs( lines ) do
      if v.type == "round_robin_row" then row_count = row_count + 1 end
    end

    frame:set_scroll_total( row_count )

    local top = QUEUE_TOP_MARGIN + column.search:GetHeight() + SEARCH_GAP

    for i, v in ipairs( lines ) do
      -- The first line is never a row, so it is never scrolled away and always sits under the box.
      local padding = i == 1 and top + v.padding or v.padding

      frame.add_line( v.type, function( _, line_frame, drawn )
        draw_queue_line( line_frame, v )

        -- The popup lays its buttons out itself, along its bottom edge, and they come last.
        if v.type == "button" then return end

        local count = #drawn
        line_frame:ClearAllPoints()

        if count == 0 then
          line_frame:SetPoint( "TOPLEFT", frame, "TOPLEFT", QUEUE_SIDE_ROOM, -padding )
        else
          line_frame:SetPoint( "TOPLEFT", drawn[ count ].frame, "BOTTOMLEFT", 0, -padding )
        end
      end, padding )
    end

    -- After the lines, since the popup resizes itself to them as each one goes in.
    local height = queue_column_height( column )

    frame:ClearAllPoints()
    frame:SetPoint( "TOPLEFT", panel, "TOPLEFT", x, -PANEL_INSET )
    frame:SetWidth( QUEUE_WIDTH )
    frame:SetHeight( height )
    frame:Show()

    return height
  end

  ---@param queue_tab { label: string, categories: string[] }
  ---@return fun(): number? -- draws the tab, and says how much of the panel it takes
  local function queue_tab_contents( queue_tab )
    return function()
      -- Nothing on the panel itself scrolls here. Told so, or the Loot tab's scrollbar would stay up.
      panel:set_scroll_total( 0 )

      local round_robin = deps.round_robin and deps.round_robin()

      -- Only before on_ready, which nobody opening the settings window can beat.
      if not round_robin then return end

      local content = queues or ar.AutoRoundRobinQueuesTab.new( round_robin, deps.add_player or function() end )
      queues = content

      local known = {}
      for _, category in ipairs( round_robin.get_categories() ) do known[ category ] = true end

      -- Half the inside of the panel each, split by the separator, with each queue in the middle of
      -- its half: the two sit the same distance from the line, and from the panel's edges.
      --
      -- Worked out in whole pixels, everything from the line outwards. Halving the panel's width
      -- lands a queue on a fraction of a pixel, and the queue's thin scrollbar with it; the client
      -- draws a texture that starts partway into a pixel across every pixel it touches, so each
      -- side rounded its bar differently and one looked wider than the other.
      local width = panel_width() or 0
      local half = math.max( math.floor( (width - PANEL_INSET * 2) / 2 ), QUEUE_WIDTH )
      local gap = math.floor( (half - QUEUE_WIDTH) / 2 )
      local line = PANEL_INSET + half
      local lefts = { line - gap - QUEUE_WIDTH, line + SEPARATOR_WIDTH + gap }
      local height = 0

      for index, category in ipairs( queue_tab.categories ) do
        if known[ category ] then
          height = math.max( height, add_queue_column( content, index, category, lefts[ index ] ) )
        end
      end

      if height == 0 then return 0 end

      local content_height = height - QUEUE_PANEL_TRIM
      draw_separator( line, content_height )

      return content_height
    end
  end

  local tab_contents = {
    add_general_tab,
    add_loot_tab,
    queue_tab_contents( QUEUE_TABS[ 1 ] ),
    queue_tab_contents( QUEUE_TABS[ 2 ] )
  }

  -- The Loot tab and the queues each scroll, and a list scrolled halfway down would open another
  -- one halfway down too. Each tab starts at the top instead; an empty list is what sends a frame
  -- back there.
  ---@param index number
  local function switch_to( index )
    if index ~= selected_tab then
      if panel then panel:set_scroll_total( 0 ) end

      for _, column in pairs( columns ) do column.frame:set_scroll_total( 0 ) end
    end

    selected_tab = index
  end

  -- Rebuilt from scratch on every visit, because every checkbox on it has to show what is
  -- true now -- all of these can be changed from a slash command, or by another page,
  -- between one viewing and the next. Switching tabs takes the same path.
  show = function()
    if not popup then popup = create_popup() end
    if not panel then panel = create_panel() end

    popup:clear()
    panel:clear()
    panel_lines = {}
    drawn_columns = {}
    separator_drawn = false

    add_page_line( "section_header", nil, function( frame )
      frame:SetText( m.colors.blue( "Summary" ) )
    end )

    add_page_line( "paragraph", "section_header", function( frame )
      local width = paragraph_width( frame )
      if width then frame:SetWidth( width ) end

      frame:SetText( SUMMARY )
    end )

    local tabs = add_page_line( "tabs", "paragraph", function( frame )
      frame:SetTabs( TABS, selected_tab )
      frame.on_select = function( index )
        switch_to( index )
        show()
      end
    end )

    local content_height = tab_contents[ selected_tab ]()
    fit_panel( tabs.frame, content_height )

    for _, column in pairs( columns ) do
      if not drawn_columns[ column ] then column.frame:Hide() end
    end

    if separator and not separator_drawn then separator:Hide() end

    popup:Show()
    panel:Show()
  end

  -- A page that isn't on screen has nothing to correct: show() reads everything afresh on the way
  -- up, so the next visit is current either way.
  local function refresh()
    if popup and popup:IsVisible() then show() end
  end

  -- Opens the page on the named tab. Redraws straight away if the page is already on screen,
  -- since the options window only refreshes a page when it switches to it.
  ---@param label string
  local function select_tab( label )
    for index, tab_label in ipairs( TABS ) do
      if tab_label == label then switch_to( index ) end
    end

    refresh()
  end

  return {
    show = show,
    refresh = refresh,
    select_tab = select_tab,
    get_frame = function() return popup end,
    get_panel = function() return panel end,
    get_queue_columns = function() return columns end,
    get_separator = function() return separator end
  }
end

-- For /rf autorobin, which opens the tab a queue is on by the queue's name, and says how to use
-- it the way the summary does.
M.QUEUE_TABS = QUEUE_TABS
M.command_choices = command_choices

ar.OptionsPage = M
return M
