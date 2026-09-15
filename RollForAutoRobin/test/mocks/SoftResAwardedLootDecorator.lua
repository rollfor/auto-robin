-- EXTENSION: stands in for the source extension's awarded-loot link.
--
-- Core used to ship src/SoftResAwardedLootDecorator.lua; it is RollForSoftRes's now, and
-- this suite does not load that addon. But the harness has to stop offering an item to a
-- player who already won it, as the game would -- which is this behaviour. So the harness
-- carries a copy, kept deliberately identical to RollForSoftRes's own.

local m = RollFor

local filter = m.filter
local alid = m.AwardedLoot.awarded_loot_item_data

local M = {}

---@param awarded_loot AwardedLoot
---@param softres SoftRes
function M.new( awarded_loot, softres )
  local function get( item_data )
    return filter( softres.get( item_data ), function( v )
      local al_item = alid( item_data.item_id, item_data.item_quantity )
      return not awarded_loot.has_item_been_awarded( v.name, al_item )
    end )
  end

  local decorator = m.clone( softres )
  decorator.get = get

  local original_is_item_hardressed = decorator.is_item_hardressed

  ---@param item_id ItemId
  local function is_item_hardressed( item_id )
    local al_item = alid( item_id, 1 )
    return original_is_item_hardressed( item_id ) and not awarded_loot.has_item_been_awarded_to_any_player( al_item )
  end

  decorator.is_item_hardressed = is_item_hardressed

  return decorator
end

return M
