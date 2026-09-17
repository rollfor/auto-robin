RollForAutoRobin = RollForAutoRobin or {}
local ar = RollForAutoRobin

if ar.RoundRobinWidgets then return end

-- Core's shared helpers. RollFor is guaranteed to be loaded: the TOC declares it as a
-- dependency, so the client refuses to load this addon without it.
local m = RollFor

-- This addon's row widgets.
--
-- Named RoundRobinWidgets rather than GuiElements so it cannot shadow core's file of that
-- name: both addons' src directories are on the same Lua path in the test harness, and the
-- first match wins.
--
-- FrameBuilder resolves a row by looking its line type up in the gui_elements table, so an
-- extension adding row types is a matter of writing keys into that table. These three are
-- written into ctx.gui_elements during on_enable, which is before any window is built.
--
-- They lived in core's GuiElements when the rotation did. Nothing in core draws them now.

local M = {}

-- Row styling core's list rows shared when there were more of them. Kept here rather than in
-- core: these are the last rows using it, so a shared helper would have exactly one caller.
local row_header_color = { 0.6, 0.65, 0.76 }
local row_text_color = { 1, 1, 1 }
-- Enough to tell which row the cursor is on across the columns, not enough to compete with
-- the values themselves.
local row_hover_color = { 0.351, 0.553, 1.0, 0.18 }
-- How far the highlight reaches past the row on each side. The popup is the widest row plus
-- its side margin, so this stays inside the frame.
local row_hover_overhang = 10


-- Same fixed-geometry reasoning as the rows above: the popup sizes itself from the widest line,
-- so a self-measuring row would be a different width per player and the rows would drift.
--
-- One column and three buttons, and no column title above them: the queue is ordered, so the row
-- above yours is ahead of you, and a header reading "Player" over a list of players says nothing
-- the list did not. The arrows move that one player; removing is an x rather than a confirmation,
-- because putting somebody back is one click of Add.
--
-- The buttons are the client's own textured templates rather than text on a UIPanelButton: the
-- scroll arrows already mean "move this up/down" everywhere else in the UI, and they carry
-- Pushed, Highlight and -- the one that matters here -- Disabled artwork, so an arrow at the end
-- of the list looks unavailable instead of merely doing nothing.
--
-- The templates are their own fixed sizes (18x16 for the arrows, 32x32 for the close button),
-- so each is scaled to sit in a 16px row rather than resized -- scaling keeps the artwork's
-- proportions, and SetWidth on a textured button stretches it.
local round_robin_row_height = 16
-- The name column is a fixed 108 like every other player column in this file, because a character
-- name is at most 12 characters and that is what 12 of them measure. It was 130, which left a
-- short name painting into a third of its own box and reading as a gap before the buttons; the
-- row width came down with it so the buttons sit just past the longest name, not past the box.
--
-- Some gap is left on purpose. The column is fixed rather than sized per name so the buttons line
-- up in a column down the list -- an x that moved left and right as the names changed length
-- would be much harder to hit than a few pixels of air.
-- Widened by exactly the checkbox column below, so the name column keeps the width it was sized
-- to and the right-anchored buttons ride out with the edge.
local round_robin_row_width = 194
local round_robin_checkbox_size = 14
local round_robin_checkbox_x = 4
local round_robin_name_x = 26
local round_robin_name_width = 108

-- A transient is a player this queue will not carry into the next group, which is exactly what
-- the unticked box says -- but a box is easy to miss in a list of forty, so the name says it too.
-- Faded rather than recoloured: the name carries its class colour, and overwriting that to say
-- something about the queue would cost the one thing the colour is there for.
local transient_row_alpha = 0.5

-- Right to left from the row's right edge, so the buttons line up in a column down the list.
-- UIPanelCloseButton would hide its parent on click -- the row -- so the NoScripts variant is the
-- one to hang our own handler off.
--
-- The offsets account for each template's own scaled width (32x0.55 and 18x0.85 on screen), so
-- they clear each other by a couple of pixels rather than by whatever the arithmetic happened to
-- leave.
local round_robin_buttons = {
  { field = "remove", template = "UIPanelCloseButtonNoScripts", scale = 0.55, x = 2 },
  { field = "down", template = "UIPanelScrollDownButtonTemplate", scale = 0.85, x = -18 },
  { field = "up", template = "UIPanelScrollUpButtonTemplate", scale = 0.85, x = -35 }
}

-- A row in the auto round robin queue: core, the player, then up / down / remove.
--
-- The checkbox is core (see AutoRoundRobin), not selection and not eligibility: ticked means the
-- player stays when the group turns over. Same template and size the auto-loot tree uses, so the
-- two windows tick the same way.
function M.round_robin_row( parent )
  local container = m.api.CreateFrame( "Frame", nil, parent )
  container:SetHeight( round_robin_row_height )
  container:SetWidth( round_robin_row_width )

  -- Reaches a little past the row on both sides so it reads as a band rather than a box around
  -- the text, the way core's list rows always did.
  local hover_highlight = container:CreateTexture( nil, "BACKGROUND" )
  hover_highlight:SetTexture( "Interface\\Buttons\\WHITE8x8" )
  hover_highlight:SetVertexColor( unpack( row_hover_color ) )
  hover_highlight:SetPoint( "TOPLEFT", container, "TOPLEFT", -row_hover_overhang, 1 )
  hover_highlight:SetPoint( "BOTTOMRIGHT", container, "BOTTOMRIGHT", row_hover_overhang, -1 )
  hover_highlight:Hide()

  local is_header = false

  local core = m.api.CreateFrame( "CheckButton", nil, container, "UICheckButtonTemplate" )
  core:SetWidth( round_robin_checkbox_size )
  core:SetHeight( round_robin_checkbox_size )
  core:SetPoint( "LEFT", container, "LEFT", round_robin_checkbox_x, 0 )

  core:SetScript( "OnClick", function()
    -- The queue is what says whether this player is core; the box only reports it. So the click
    -- is handed on with what it is asking for and the row is redrawn from the answer, rather than
    -- the box being left showing a state nothing has agreed to yet.
    local callback = container.on_toggle_core
    if callback then callback( core:GetChecked() and true or false ) end
  end )

  local name = container:CreateFontString( nil, "ARTWORK", "GameFontNormalSmall" )
  name:SetWidth( round_robin_name_width )
  name:SetHeight( round_robin_row_height )
  name:SetJustifyH( "LEFT" )
  name:SetTextColor( unpack( row_text_color ) )
  name:SetPoint( "LEFT", container, "LEFT", round_robin_name_x, 0 )

  local buttons = {}

  for _, definition in ipairs( round_robin_buttons ) do
    local button = m.api.CreateFrame( "Button", nil, container, definition.template )
    button:SetScale( definition.scale )
    -- The offset is in the button's own scaled coordinates, so it is divided by the scale to keep
    -- the three of them a fixed distance apart on screen whatever each is scaled to.
    button:SetPoint( "RIGHT", container, "RIGHT", definition.x / definition.scale, 0 )

    button:SetScript( "OnClick", function()
      local callback = container[ "on_" .. definition.field ]
      if callback then callback() end
    end )

    buttons[ definition.field ] = button
  end

  -- FrameBuilder caches line frames per line type and reuses them across refreshes, so every
  -- field is written on every call -- including the callbacks, since a frame left holding the
  -- previous occupant's closure would move or remove the wrong player.
  container.SetRow = function( _, row )
    name:SetText( row.player or "" )
    name:SetAlpha( row.core and 1 or transient_row_alpha )

    core:SetChecked( row.core and true or false )

    container.on_up = row.on_up
    container.on_down = row.on_down
    container.on_remove = row.on_remove
    container.on_toggle_core = row.on_toggle_core

    -- The first row cannot move up and the last cannot move down, and a button that does
    -- nothing when clicked is worse than one that says it will not.
    if row.can_move_up then buttons.up:Enable() else buttons.up:Disable() end
    if row.can_move_down then buttons.down:Enable() else buttons.down:Disable() end

    -- Rows are recycled between refreshes and a hidden frame never gets its OnLeave, so a stale
    -- highlight would follow the frame to its next row.
    hover_highlight:Hide()
  end

  -- Nothing emits a header row for this list any more, but the queue tabs call this on every row
  -- it draws, so it stays -- and stays correct, in case one is ever wanted back.
  container.SetHeader = function( _, header )
    is_header = header and true or false

    for _, button in pairs( buttons ) do
      if is_header then button:Hide() else button:Show() end
    end

    if is_header then core:Hide() else core:Show() end

    if is_header then
      hover_highlight:Hide()
      name:SetTextColor( unpack( row_header_color ) )
    else
      name:SetTextColor( unpack( row_text_color ) )
    end
  end

  container:EnableMouse( true )

  container:SetScript( "OnEnter", function()
    if is_header then return end
    hover_highlight:Show()
  end )

  container:SetScript( "OnLeave", function()
    hover_highlight:Hide()
  end )

  -- A mouse-enabled row swallows the click a draggable parent needs to start dragging, so the row
  -- hands it back rather than making most of the frame undraggable. The options page it is drawn
  -- on now doesn't drag, and simply has nothing to hand it to.
  container:RegisterForDrag( "LeftButton" )

  local function forward_to_popup( script )
    return function()
      local handler = parent:GetScript( script )
      if handler then handler( parent ) end
    end
  end

  container:SetScript( "OnDragStart", forward_to_popup( "OnDragStart" ) )
  container:SetScript( "OnDragStop", forward_to_popup( "OnDragStop" ) )

  return container
end

-- The queue's length, sitting above the list and aligned with its right edge. Its own line type
-- rather than a header row of the list, for one reason that matters: the row type is what the
-- viewport scrolls, so a count rendered as one would scroll away with the first player and would
-- also be counted into the list's own length.
--
-- Same fixed width as a row, so "aligned with the list" is exact rather than approximate -- both
-- start at the same left edge, so equal widths put their right edges in the same place.
--
-- It costs no vertical space. The container is a sliver, and the number is drawn *above* it -- in
-- the band the line before it already occupies, which is the category picker's. A number is two
-- characters wide and the picker's right half is empty, so a line of its own would be 24 pixels
-- of page bought for nothing, and the queue would start that much further down the tab.
local round_robin_count_height = 1
local round_robin_count_lift = 5

function M.round_robin_count( parent )
  local container = m.api.CreateFrame( "Frame", nil, parent )
  container:SetHeight( round_robin_count_height )
  container:SetWidth( round_robin_row_width )

  local label = container:CreateFontString( nil, "ARTWORK", "GameFontNormalSmall" )
  label:SetJustifyH( "RIGHT" )
  label:SetTextColor( unpack( row_header_color ) )
  label:SetPoint( "BOTTOMRIGHT", container, "TOPRIGHT", -2, round_robin_count_lift )

  container.SetRow = function( _, row )
    label:SetText( row.count or "" )
  end

  return container
end

-- A labelled free-text box. The editbox above it is numeric (it backs the options window's
-- thresholds and timers); this one takes a player name, so it accepts anything and commits what
-- was typed verbatim.
local default_text_field_width = 120

function M.text_field( parent )
  local text_field_width = default_text_field_width

  local container = m.api.CreateFrame( "Frame", nil, parent )
  local edit = m.api.CreateFrame( "EditBox", nil, container, "InputBoxTemplate" )
  edit:SetWidth( text_field_width )
  edit:SetHeight( 18 )
  edit:SetAutoFocus( false )
  edit:SetFontObject( m.api.GameFontHighlightSmall )

  local label = container:CreateFontString( nil, "ARTWORK", "GameFontNormalSmall" )
  label:SetTextColor( 1, 1, 1 )
  label:SetPoint( "LEFT", container, "LEFT", 0, 0 )

  edit:SetPoint( "LEFT", label, "RIGHT", 16, 0 )
  container:SetHeight( edit:GetHeight() )

  -- The container is what the popup measures, so it is recomputed whenever either the label or
  -- the box changes width.
  local function resize()
    container:SetWidth( label:GetWidth() + 16 + text_field_width + 8 )
  end

  container.SetText = function( _, text )
    label:SetText( text )
    resize()
  end

  -- Caps what can be typed. A character name is at most 12 letters, and a box that lets you type
  -- past that is a box that lets you queue somebody who cannot exist.
  ---@param max number? -- nil for no limit
  container.SetMaxLetters = function( _, max )
    edit:SetMaxLetters( max or 0 )
  end

  ---@param width number? -- nil restores the default
  container.SetFieldWidth = function( _, width )
    text_field_width = width or default_text_field_width
    edit:SetWidth( text_field_width )
    resize()
  end

  container.SetValue = function( _, value )
    edit:SetText( value or "" )
  end

  container.GetValue = function()
    return edit:GetText()
  end

  container.SetFocus = function()
    edit:SetFocus()
  end

  -- Enter is the fast path for a one-field form, so it submits rather than merely committing.
  edit:SetScript( "OnEnterPressed", function()
    if container.on_enter then container.on_enter() end
  end )

  edit:SetScript( "OnEscapePressed", function()
    edit:ClearFocus()
    if container.on_escape then container.on_escape() end
  end )

  edit:SetScript( "OnTextChanged", function()
    if container.on_change then container.on_change( edit:GetText() ) end
  end )

  return container
end


-- A queue row's fixed size, for laying out a column of them before any row exists: an empty queue
-- still takes the room its rows would.
M.ROW_WIDTH = round_robin_row_width
M.ROW_HEIGHT = round_robin_row_height

-- Written into core's table, which is what FrameBuilder resolves rows against. Called from
-- on_enable, before anything builds a window.
---@param gui_elements table -- ctx.gui_elements
function M.register( gui_elements )
  gui_elements.round_robin_row = M.round_robin_row
  gui_elements.round_robin_count = M.round_robin_count
  gui_elements.text_field = M.text_field
end

ar.RoundRobinWidgets = M
return M
