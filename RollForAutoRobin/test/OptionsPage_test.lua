package.path = "./?.lua;" .. package.path .. ";../../deps/rollfor/RollFor/src/?.lua;../../deps/rollfor/RollFor/src/libs/?.lua;../src/?.lua;../../?.lua;../../deps/rollfor/?.lua"

-- This addon builds its own page in RollFor's options window. Core supplies the canvas
-- and the builders and asks for it; what ends up on it is entirely ours, which is the
-- point -- an extension keeps its own database, so core cannot know what belongs there.
--
-- The doubles are local rather than borrowed from RollFor's test harness. Core's options
-- tests spy on its content transformer, which this page does not use: it talks to the
-- popup builder directly. Owning the page means owning the double for it.

require( "src/compat" )
local u = require( "RollForAutoRobin/test/utils" )
local lu, eq = u.luaunit( "assertEquals" )
require( "src/modules" )
u.multi_require_src( "DebugBuffer", "Module", "Types" )

u.mock_wow_api()
u.load_extension()

local OptionsPage = RollForAutoRobin.OptionsPage

-- Widgets that record what was done to them, so a test can ask what the page put on a
-- line rather than what it looks like on screen. What the real widgets draw is RollFor's
-- business, and the game's.
local function fake_widget()
  local widget = {}

  widget.SetText = function( _, text ) widget.text = text end
  widget.SetChecked = function( _, checked ) widget.checked = checked end
  widget.SetWidth = function( _, width ) widget.width = width end
  widget.GetWidth = function() return widget.width or 0 end
  widget.ClearAllPoints = function() end
  widget.SetPoint = function() end
  widget.Show = function() end
  widget.Hide = function() end

  return widget
end

local function fake_gui_elements()
  local elements = {}

  for _, line_type in ipairs( { "section_header", "paragraph", "checkbox" } ) do
    elements[ line_type ] = fake_widget
  end

  return elements
end

-- A popup that keeps its lines, which is the whole of what this page does with one.
local function recording_popup_builder()
  local builder = {}
  local popup = { lines = {}, visible = false }

  popup.add_line = function( line_type, modify_fn, padding )
    local frame = fake_widget()
    modify_fn( line_type, frame, popup.lines )

    local line = { line_type = line_type, frame = frame, padding = padding }
    table.insert( popup.lines, line )

    return line
  end

  popup.clear = function() popup.lines = {} end
  popup.Show = function() popup.visible = true end
  popup.IsVisible = function() return popup.visible end

  -- Every setter the page chains, answering with itself.
  for _, setter in ipairs( {
    "name", "parent", "point", "gui_elements", "backdrop_color", "no_border"
  } ) do
    builder[ setter ] = function( self ) return self end
  end

  builder.build = function() return popup end

  return builder
end

-- What core hands over: the builders, this extension's own on/off state, and the config its
-- settings were registered into. Not the summary -- that is ours, and lives in the page.
---@param overrides table?
local function mock_context( overrides )
  local state = { enabled = true, set_to = nil, settings = {
    auto_round_robin = true,
    auto_round_robin_announce = true,
    auto_round_robin_announce_drops = false
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
---@param canvas_width number?
local function shown_page( ctx, canvas_width )
  local canvas = u.modules().api.CreateFrame( "Frame" )
  canvas.GetWidth = function() return canvas_width or CANVAS_WIDTH end

  local page = OptionsPage.new( ctx, canvas )
  page.show()

  return page
end

---@return string[]
local function line_types( page )
  local result = {}

  for _, line in ipairs( page.get_frame().lines ) do
    table.insert( result, line.line_type )
  end

  return result
end

---@return table
local function line( page, line_type )
  for _, entry in ipairs( page.get_frame().lines ) do
    if entry.line_type == line_type then return entry.frame end
  end

  error( string.format( "There was no %s on the page.", line_type ), 2 )
end


---@return table
local function checkbox( page, label )
  for _, entry in ipairs( page.get_frame().lines ) do
    if entry.line_type == "checkbox" and entry.frame.text == label then return entry.frame end
  end

  error( string.format( "There was no %q checkbox on the page.", label ), 2 )
end

OptionsPageSpec = {}

-- Summary first, switches second: a checkbox means nothing until you know what it is you
-- would be turning on.
function OptionsPageSpec:should_show_a_summary_then_the_switches()
  local page = shown_page( mock_context() )

  eq( line_types( page ),
    { "section_header", "paragraph", "checkbox", "checkbox", "checkbox" } )
end

-- This addon's own copy, not something core handed over. Matched on what the rotation
-- actually does rather than the opening line, which is the part most likely to get
-- reworded.
function OptionsPageSpec:should_say_what_the_rotation_does()
  local page = shown_page( mock_context() )
  local summary = line( page, "paragraph" ).text

  eq( string.find( summary, "rotation", 1, true ) ~= nil, true )
  eq( string.find( summary, "One queue per category", 1, true ) ~= nil, true )
end

ExtensionSwitchSpec = {}

-- No Enabled switch, because "Auto round robin" is already it: two switches for one question
-- could disagree, and Auto round robin ticked on a disabled extension reads as broken. The
-- addon declares hide_enabled_option, so core draws none either and keeps the extension on --
-- which is what makes leaving it off this page safe rather than a way to strand somebody.
function ExtensionSwitchSpec:should_not_draw_an_enabled_switch()
  local page = shown_page( mock_context() )

  for _, entry in ipairs( page.get_frame().lines ) do
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
