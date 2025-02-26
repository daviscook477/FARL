require '__FARL__/stdlib/string'
require '__FARL__/stdlib/table'
require "__FARL__/FarlSettings"
require "__FARL__/FARL"
require "__FARL__/GUI"
local lib = require "__FARL__/lib_control"
local saveVar = lib.saveVar
local debugDump = lib.debugDump
local mod_gui = require '__core__/lualib/mod-gui'

local Position = require '__FARL__/stdlib/area/position'

local v = require '__FARL__/semver'

local MOD_NAME = "FARL"

local function resetMetatable(o, mt)
    setmetatable(o,{__index=mt})
    return o
end

local function setMetatables()
    for i, farl in pairs(global.farl) do
        global.farl[i] = resetMetatable(farl, FARL)
    end
    for name, s in pairs(global.players) do
        global.players[name] = resetMetatable(s,Settings)
    end
end

local function getRailTypes()
    global.rails = {}
    global.rails_by_index = {}
    global.rails_localised = {}
    local rails_by_item = {
        rail = {
            curved = "curved-rail",
            straight = "straight-rail",
            item = "rail"
        }
    }
    local curved, straight = game.entity_prototypes["curved-rail"], game.entity_prototypes["straight-rail"]
    if curved and straight then
        local vanilla = 0
        if curved.items_to_place_this then
            for _, item in pairs(curved.items_to_place_this) do
                if item.name == "rail" then
                    vanilla = 1
                end
            end
        end
        if straight.items_to_place_this then
            for _, item in pairs(straight.items_to_place_this) do
                if item.name == "rail" then
                    vanilla = vanilla + 1
                end
            end
        end
        if vanilla ~= 2 then
            rails_by_item = {}
        end
    end
    --local items = game.get_filtered_item_prototypes{{filter="place-result", elem_filters={{filter="rail"}}}}
    local railstring = ""
    local rails = game.get_filtered_entity_prototypes({{filter="rail"}})
    for name, proto in pairs(rails) do
        if proto.type == "straight-rail" and proto.items_to_place_this then
            for _, item in pairs(proto.items_to_place_this) do
                if not rails_by_item[item.name] then
                    rails_by_item[item.name] = {}
                end
                if not rails_by_item[item.name].straight then
                    rails_by_item[item.name].straight = name
                    rails_by_item[item.name].item = item.name
                end
            end
        end
        if proto.type == "curved-rail" and proto.items_to_place_this then
            for _, item in pairs(proto.items_to_place_this) do
                --log(serpent.block(item))
                local item_proto = game.item_prototypes[item.name]
                --log(serpent.block(item_proto.place_result.name))
                if item_proto and game.entity_prototypes[item_proto.place_result.name].type == "straight-rail" then
                    if not rails_by_item[item.name] then
                        rails_by_item[item.name] = {}
                    end
                    if not rails_by_item[item.name].curved then
                        rails_by_item[item.name].curved = name
                    end
                end
            end
        end
    end
    local index = 1
    if rails_by_item.rail then
        rails_by_item.rail.index = index
        global.rails_by_index[index] = rails_by_item.rail
        global.rails_localised[index] = game.item_prototypes["rail"].localised_name
        index = index + 1
        railstring = railstring .. "rail"
    end

    for item, rails in pairs(rails_by_item) do
        if item ~= "rail" and rails.straight and rails.curved then
            rails.index = index
            global.rails_by_index[index] = rails_by_item[item]
            global.rails_localised[index] = game.item_prototypes[item].localised_name
            index = index + 1
            railstring = railstring .. item
        end
    end
    --log(serpent.block(rails_by_item))
    local rails_encoded = game.encode_string(game.table_to_json(rails_by_item))
    global.rails = rails_by_item
    return railstring, rails_encoded
end

local function on_tick(event)
    local status, err = pcall(function()

        if global.overlayStack and global.overlayStack[event.tick] then
            for _, overlay in pairs(global.overlayStack[event.tick]) do
                if overlay.valid then
                    overlay.destroy()
                end
            end
            global.overlayStack[event.tick] = nil
        end

        --for i, farl in pairs(global.farl) do
        for _, farl in pairs(global.activeFarls) do
            if farl.driver and farl.driver.valid then
                local status, err = pcall(function()
                    if farl:update(event) then
                        GUI.updateGui(farl)
                    end
                end)
                if not status then
                    if farl and farl.active then
                        farl:deactivate("Unexpected error: "..err)
                    end
                    debugDump("Unexpected error: "..err,true)
                end
            end
        end
    end)
    if not status then
        debugDump("Unexpected error:",true)
        debugDump(err,true)
    end
end

local function init_global()
    global = global or {}
    global.players =  global.players or {}
    global.savedBlueprints = global.savedBlueprints or {}
    global.farl = global.farl or {}
    global.activeFarls = global.activeFarls or {}
    global.railInfoLast = global.railInfoLast or {}
    global.electricInstalled = remote.interfaces.dim_trains and remote.interfaces.dim_trains.railCreated
    global.overlayStack = global.overlayStack or {}
    global.statistics = global.statistics or {}
    global.version = global.version or "0.5.35"
    global.railString = global.railString or "rail"
    global.rails_by_index = global.rails_by_index or {}
    global.rails_localised = global.rails_localised or {}
    global.rails =  global.rails or {
        rail = {curved = "curved-rail", straight = "straight-rail", index = 1, item="rail"}
    }
    if global.debug_log == nil then
        global.debug_log = false
    end
    setMetatables()
end

local function init_player(player)
    Settings.loadByPlayer(player)
    global.savedBlueprints[player.index] = global.savedBlueprints[player.index] or {}
end

local function init_players()
    for _, player in pairs(game.players) do
        init_player(player)
    end
end

local function init_force(force)
    if not global.statistics then
        init_global()
    end
    global.statistics[force.name] = global.statistics[force.name] or {created={}, removed={}}
end

local function init_forces()
    for _, f in pairs(game.forces) do
        init_force(f)
    end
end

--when Player is in a FARL and used FatController to switch to another train
local function on_player_switched(event)
    local status, err = pcall(function()
        if FARL.isFARLLocomotive(event.carriage) then
            local farl = FARL.findByLocomotive(event.carriage)
            if farl then
                farl:deactivate()
            end
        end
    end)
    if not status then
        debugDump("Unexpected error:",true)
        debugDump(err,true)
    end
end

local function register_events()
    if remote.interfaces.fat and remote.interfaces.fat.get_player_switched_event then
        script.on_event(remote.call("fat", "get_player_switched_event"), on_player_switched)
    end
end

local function on_init()
    register_events()
    init_global()
    init_forces()
    init_players()
    setMetatables()
    global.railString, global.encoded_rails = getRailTypes()
end

local function on_load()
    register_events()
    setMetatables()
end

local function reset_rail_types()
    for _, player in pairs(game.players) do
        player.print("Rail types where changed, resetting to vanilla rail.")
        local psettings = global.players[player.index]
        if psettings then
            psettings.railType = 1
            psettings.rail = global.rails_by_index[1]
        end
    end
end

local function on_configuration_changed(data)
    if data.mod_changes[MOD_NAME] then
        local newVersion = data.mod_changes[MOD_NAME].new_version
        newVersion = v(newVersion)
        local oldVersion = data.mod_changes[MOD_NAME].old_version
        if oldVersion then
            oldVersion = v(oldVersion)
            log("FARL version changed from ".. tostring(oldVersion) .." to ".. tostring(newVersion))
            if oldVersion > newVersion then
                debugDump("Downgrading FARL, reset settings",true)
                global = {}
                on_init()
            else
                if oldVersion < v'3.0.0' then
                    debugDump("FARL: Reset settings",true)
                    global = {}
                end
                on_init()
                if oldVersion < v'3.0.1' then
                    for _, psettings in pairs(global.players) do
                        if psettings.player then
                            psettings.player = nil
                        end
                    end
                end
                if oldVersion < v'3.0.2' then
                    global.godmode = nil
                    for _, psettings in pairs(global.players) do
                        psettings.remove_cliffs = true
                    end
                end
                if oldVersion < v'3.1.4' then
                    local invalids = 0
                    for i, farl in pairs(global.farl) do
                        if (not farl.train or (farl.train and not farl.train.valid)) or (not farl.locomotive or (farl.locomotive and not farl.locomotive.valid)) then
                            if farl.driver and farl.driver.valid then
                                GUI.destroyGui(farl.driver)
                            end
                            farl:deactivate()
                            invalids = invalids + 1
                            global.activeFarls[i] = nil
                            global.farl[i] = nil
                        end
                    end
                    if invalids > 0 then
                        log("Deactivated " .. invalids .. "FARL trains")
                    end
                end
                if oldVersion < v'3.1.6' then
                    local farl
                    for _, player in pairs(game.players) do
                        if player.gui.left.farl and player.gui.left.farl.valid then
                            FARL.onPlayerLeave(player)
                            player.gui.left.farl.destroy()
                            farl = FARL.onPlayerEnter(player)
                            GUI.createGui(player)
                            if farl then
                                GUI.updateGui(farl)
                            end
                        end
                    end
                end
                if oldVersion < v'3.1.11' then
                    for _, psettings in pairs(global.players) do
                        psettings.flipPoles = false
                    end
                end
                global.trigger_events = nil

                if oldVersion < v'4.0.3' then
                    for i, player in pairs(game.players) do
                        local psettings = global.players[i]
                        psettings.bp = {diagonal=defaultsDiagonal, straight=defaultsStraight}
                        psettings.activeBP = psettings.bp
                        global.savedBlueprints[i] = {}
                        player.print("FARL: Cleared blueprints")
                    end
                    local farl, frame_flow
                    for _, player in pairs(game.players) do
                        frame_flow = mod_gui.get_frame_flow(player)
                        if frame_flow.farl and frame_flow.farl.valid then
                            FARL.onPlayerLeave(player)
                            frame_flow.farl.destroy()
                            farl = FARL.onPlayerEnter(player)
                            if farl then
                                farl:deactivate()
                                GUI.createGui(player)
                                GUI.updateGui(farl)
                            end
                        end
                    end
                end
                if oldVersion < v'4.0.4' then
                    local railstring, encoded_rails = getRailTypes()
                    reset_rail_types()
                    global.railString = railstring
                    global.encoded_rails = encoded_rails
                end
            end
        else
            debugDump("FARL version: ".. tostring(newVersion), true)
        end
        on_init()
        global.version = tostring(newVersion)
    end

    if data.mod_startup_settings_changed then
        local tech_name = game.active_mods["IndustrialRevolution"] and "automated-rail-transportation" or "rail-signals"
        for _, force in pairs(game.forces) do
            if force.technologies[tech_name].researched then
                force.recipes["farl"].enabled = true
                if settings.startup.farl_enable_module.value then
                    force.recipes["farl-roboport"].enabled = true
                end
            end
        end
    end
    --  if remote.interfaces["satellite-uplink"] and remote.interfaces["satellite-uplink"].add_allowed_item then
    --    log("registered")
    --    remote.call("satellite-uplink", "add_allowed_item", "rail")
    --    remote.call("satellite-uplink", "add_item", "rail", 1)
    --  end

    local railstring, encoded_rails = getRailTypes()
    --rails where added/removed, reset to index 1
    --log(string.format("%s == %s", railstring, global.railString))
    if railstring ~= global.railString or encoded_rails ~= global.encoded_rails then
        reset_rail_types()
    end
    global.railString = railstring
    global.encoded_rails = encoded_rails
    setMetatables()
    for _,s in pairs(global.players) do
        s:checkMods()
    end
end

local function on_player_created(event)
    init_player(game.get_player(event.player_index))
end

local function on_force_created(event)
    init_force(event.force)
end

local function on_gui_click(event)
    local status, err = pcall(function()
        local index = event.player_index
        local player = game.get_player(index)
        if mod_gui.get_frame_flow(player).farl ~= nil then
            local farl = FARL.findByPlayer(player)
            if farl then
                GUI.onGuiClick(event, farl, player)
                GUI.updateGui(farl)
            else
                player.print("Gui without train, wrooong!")
                GUI.destroyGui(player)
            end
        end
    end)
    if not status then
        debugDump("Unexpected error:",true)
        debugDump(err,true)
    end
end

local function on_gui_checked_state_changed(event)
    local status, err = pcall(function()
        local index = event.player_index
        local player = game.get_player(index)
        if mod_gui.get_frame_flow(player).farl ~= nil then
            local farl = FARL.findByPlayer(player)
            if farl then
                GUI.on_gui_checked_state_changed(event, farl, player)
                GUI.updateGui(farl)
            else
                player.print("Gui without train, wrooong!")
                GUI.destroyGui(player)
            end
        end
    end)
    if not status then
        debugDump("Unexpected error:",true)
        debugDump(err,true)
    end
end

local function on_preplayer_mined_item(event)
    local ent = event.entity
    if ent.type == "locomotive" or ent.type == "cargo-wagon" then
        for i, farl in pairs(global.farl) do
            if not farl.train or (farl.train.valid and farl.train == ent.train) or not farl.train.valid then
                if event.player_index then
                    local player = game.get_player(event.player_index)
                    if farl.driver and farl.driver == player then
                        FARL.onPlayerLeave(player)
                        GUI.destroyGui(player)
                    end
                end
                global.farl[i]:deactivate()
                global.farl[i] = nil
                global.activeFarls[i] = nil
            end
        end
    end
end

local function on_marked_for_deconstruction(event)
    on_preplayer_mined_item(event)
end

local function on_entity_died(event)
    on_preplayer_mined_item(event)
end

local function on_player_driving_changed_state(event)
    local player = game.get_player(event.player_index)
    if FARL.isFARLLocomotive(player.vehicle) then
        if mod_gui.get_frame_flow(player).farl == nil then
            local farl = FARL.onPlayerEnter(player)
            GUI.createGui(player)
            if farl then
                GUI.updateGui(farl)
            end
        end
    end
    if player.vehicle == nil and mod_gui.get_frame_flow(player).farl ~= nil then
        FARL.onPlayerLeave(player)
        debugDump("onPlayerLeave (driving state changed)")
        GUI.destroyGui(player)
    end
end

local function on_pre_player_removed(event)
    local status, err = pcall(function()
        local pi = event.player_index
        local player = game.get_player(pi)
        global.players[pi] = nil
        global.savedBlueprints[pi] = nil
        FARL.onPlayerLeave(player)
        for i, f in pairs(global.farl) do
            if f.startedBy == player then
                f:deactivate()
            end
        end
    end)
    if not status then
        debugDump("Unexpected error:",true)
        debugDump(err, true)
    end
end

local function script_raised_destroy(event)
    if event.entity and event.entity.valid and event.entity.type == "locomotive" then
        local status, err = pcall(function()
            local id = FARL.getIdFromTrain(event.entity.train)
            local farl = global.farl[id]
            if not farl then
                return
            end
            farl:deactivate()
            if farl.driver and farl.driver.valid then
                GUI.destroyGui(farl.driver)
            end
            global.activeFarls[id] = nil
            global.farl[id] = nil
        end)
        if not status then
            debugDump("Unexpected error:",true)
            debugDump(err, true)
        end
    end
end

-- local function script_raised_built(event)
--     if event.entity and event.entity.valid and event.entity.type == "locomotive" then
--         if event.mod_name and event.mod_name == "MultipleUnitTrainControl" then
--             log(serpent.line(event))
--             -- local entity = event.entity
--             -- if entity.get_driver() then
--             --     FARL.onPlayerEnter(entity.get_driver(), entity)
--             -- end
--         end
--     end
-- end
--function on_player_placed_equipment(event)
--  local player = game.get_player(event.player_index)
--  if event.equipment.name == "farl-roboport" and isFARLLocomotive(player.vehicle) then
--    if mod_gui.get_frame_flow(player).farl == nil then
--      FARL.onPlayerEnter(player)
--      GUI.createGui(player)
--    end
--  end
--end
--
--function on_player_removed_equipment(event)
--  local player = game.get_player(event.player_index)
--  if event.equipment.name == "farl-roboport" and mod_gui.get_frame_flow(player).farl and player.vehicle then
--    if not isFARLLocomotive(player.vehicle) then
--      FARL.onPlayerLeave(player, event.tick + 5)
--      log("onPlayerLeave (equipment changed)")
--      local tick = event.tick + 5
--      if not global.destroyNextTick[tick] then
--        global.destroyNextTick[tick] = {}
--      end
--      table.insert(global.destroyNextTick[tick], event.player_index)
--    end
--  end
--end

script.on_init(on_init)
script.on_load(on_load)
script.on_configuration_changed(on_configuration_changed)
script.on_event(defines.events.on_player_created, on_player_created)
script.on_event(defines.events.on_force_created, on_force_created)

script.on_event(defines.events.on_tick, on_tick)
script.on_event(defines.events.on_gui_click, on_gui_click)
script.on_event(defines.events.on_gui_checked_state_changed, on_gui_checked_state_changed)

local stock_filter = {{filter = "rolling-stock"}}

script.on_event(defines.events.on_pre_player_mined_item, on_preplayer_mined_item, stock_filter)
script.on_event(defines.events.on_entity_died, on_entity_died, stock_filter)
script.on_event(defines.events.on_marked_for_deconstruction, on_marked_for_deconstruction, stock_filter)
script.on_event(defines.events.script_raised_destroy, script_raised_destroy)

--script.on_event(defines.events.script_raised_built, script_raised_built)

script.on_event(defines.events.on_player_driving_changed_state, on_player_driving_changed_state)

script.on_event(defines.events.on_pre_player_removed, on_pre_player_removed)

--script.on_event(defines.events.on_player_placed_equipment, on_player_placed_equipment)
--script.on_event(defines.events.on_player_removed_equipment, on_player_removed_equipment)

script.on_event(defines.events.on_player_placed_equipment, function(event)
    if event.equipment.name == "farl-roboport" then
        event.equipment.energy = 5000000000
    end
end)

script.on_event("toggle-train-control", function(event)
    if not game.active_mods["Honk"] and not game.active_mods["Honck"] then
        local player = game.get_player(event.player_index)
        local vehicle = player.vehicle
        if vehicle and vehicle.type == "locomotive" then
            vehicle.train.manual_mode = not vehicle.train.manual_mode
            if player.mod_settings.farl_display_messages.value then
                local mode = vehicle.train.manual_mode and {"gui-train.manual-mode"} or {"gui-train.automatic-mode"}
                player.print({"msg-train-toggled", mode})
            end
        end
    end
end)

script.on_event("farl-toggle-cruise-control", function(event)
    local player = game.get_player(event.player_index)
    local vehicle = player.vehicle
    if vehicle and FARL.isFARLLocomotive(vehicle) then
        local farl = FARL.findByPlayer(player)
        if farl then farl:toggleCruiseControl() end
    end
end)

script.on_event("farl-toggle-active", function(event)
    local player = game.get_player(event.player_index)
    local vehicle = player.vehicle
    if vehicle and FARL.isFARLLocomotive(vehicle) then
        local farl = FARL.findByPlayer(player)
        if farl then
            if farl.active then
                farl:deactivate()
            else
                farl:activate()
            end
        end
    end
end)

local command_to_button = {
    farl_read_bp = "blueprint",
    farl_clear_bp = "bpClear",
    farl_vertical_bp = "blueprint_concrete_vertical",
    farl_diagonal_bp = "blueprint_concrete_diagonal"
}
local function farl_command(data)
    local player = game.get_player(data.player_index)
    if not player.vehicle or not (FARL.isFARLLocomotive(player.vehicle)) then
        player.print("You need to be in a FARL to use this command")
        return
    end
    data.element = {name = command_to_button[data.name], player_index = data.player_index}
    log(serpent.block(data))
    on_gui_click(data)
end

commands.add_command("farl_read_bp", "Read the blueprint/book on the cursor", farl_command)
commands.add_command("farl_clear_bp", "Clear stored layout", farl_command)
commands.add_command("farl_vertical_bp", "Create vertical blueprint", farl_command)
commands.add_command("farl_diagonal_bp", "Create diagonal blueprint", farl_command)
commands.add_command("farl_flipPoles", "Flip the side of the electric pole", function(data)
    local player = game.get_player(data.player_index)
    local psettings = Settings.loadByPlayer(player)
    psettings.flipPoles = not psettings.flipPoles
    player.print("flipPoles: " .. tostring(psettings.flipPoles))
end)

remote.add_interface("farl",
    {
        railInfo = function(rail)
            rail = rail or game.player.selected
            debugDump(rail.name.."@ ".. Position.tostring(rail.position).." dir:"..rail.direction.." realPos: "..Position.tostring(lib.diagonal_to_real_pos(rail)),true)
            if type(global.railInfoLast) == "table" and global.railInfoLast.valid then
                local pos = global.railInfoLast.position
                local diff=Position.subtract(rail.position,pos)
                local rdiff = Position.subtract(lib.diagonal_to_real_pos(rail),lib.diagonal_to_real_pos(global.railInfoLast))
                debugDump("Offset from last: x="..diff.x..",y="..diff.y,true)
                debugDump("real Offset: x="..rdiff.x..",y="..rdiff.y,true)
                debugDump("Distance (util): "..util.distance(pos, rail.position),true)
                --debugDump("lag for diag: "..(diff.x-diff.y),true)
                --debugDump("lag for straight: "..(diff.y+diff.x),true)
                global.railInfoLast = false
            else
                global.railInfoLast = rail
            end
        end,
        --/c remote.call("farl", "debugInfo")
        debugInfo = function()
            saveVar(global, "console")
            --saveVar(global.debug, "RailDebug")
        end,
        reset = function()
            global = {}
            if game.forces.player.technologies["rail-signals"].researched then
                game.forces.player.recipes["farl"].enabled = true
                game.forces.player.recipes["farl-roboport"].enabled = true
            end
            local farl
            for _, player in pairs(game.players) do
                if player.gui.left.farl and player.gui.left.farl.valid then
                    farl = FARL.findByPlayer(player)
                    if farl then
                        farl:deactivate()
                        if mod_gui.get_frame_flow(player).farl == nil then
                            farl = FARL.onPlayerEnter(player)
                            GUI.createGui(player)
                            if farl then
                                GUI.updateGui(farl)
                            end
                        end
                    end
                    player.gui.left.farl.destroy()
                end
            end
            for _,p in pairs(game.players) do
                if p.gui.left.farl then p.gui.left.farl.destroy() end
                if mod_gui.get_frame_flow(p).farl then mod_gui.get_frame_flow(p).farl.destroy() end
                if p.gui.top.farl then p.gui.top.farl.destroy() end
            end
            on_init()
        end,

        setCurvedWeight = function(weight, player)
            local s = Settings.loadByPlayer(player)
            s.curvedWeight = weight
        end,

        setSpeed = function(speed)
            for _, s in pairs(global.players) do
                s.cruiseSpeed = speed
            end
        end,

        tileAt = function(x,y)
            debugDump(game.surfaces[game.player.surface].get_tile(x, y).name,true)
        end,

        quickstart = function(player)
            local items = {"farl", "straight-rail", "medium-electric-pole", "big-electric-pole",
                "small-lamp", "solid-fuel", "rail-signal", "blueprint", "cargo-wagon"}
            local count = {5,100,50,50,50,50,50,10,5}
            player = player or game.player
            for i=1,#items do
                player.insert{name=items[i], count=count[i]}
            end
        end,
        quickstart2 = function(player)
            local items = {"power-armor-mk2", "personal-roboport-equipment", "fusion-reactor-equipment",
                "blueprint", "deconstruction-planner", "construction-robot", "exoskeleton-equipment"}
            local count = {1,5,3,1,1,50,2}
            player = player or game.player
            for i=1,#items do
                player.insert{name=items[i], count=count[i]}
            end
        end,

        quickstartElectric = function()
            local items = {"farl", "curved-power-rail", "straight-power-rail", "medium-electric-pole", "big-electric-pole",
                "small-lamp", "solid-fuel", "rail-signal", "blueprint", "electric-locomotive", "solar-panel", "basic-accumulator"}
            local count = {5,50,50,50,50,50,50,50,10,2,50,50}
            for i=1,#items do
                game.player.insert{name=items[i], count=count[i]}
            end
        end,

        debuglog = function()
            global.debug_log = not global.debug_log
            local state = global.debug_log and "on" or "off"
            debugDump("Debug: "..state,true)
        end,

        revive = function(player)
            for _, entity in pairs(player.surface.find_entities_filtered{area = Position.expand_to_area(player.position,50), type = "entity-ghost"}) do
                entity.revive()
            end
        end,

        tile_properties = function(player)
            local x = player.position.x
            local y = player.position.y
            local tile = player.surface.get_tile(x,y)
            local tprops = player.surface.get_tileproperties(x,y)
            player.print(tile.name)
            local properties = {
                tierFromStart = tprops.tier_from_start,
                roughness = tprops.roughness,
                elevation = tprops.elevation,
                availableWater = tprops.available_water,
                temperature = tprops.temperature
            }
            for k,p in pairs(properties) do
                player.print(k.." "..p)
            end
        end,

        fake_signals = function(bool)
            global.fake_signals = bool
        end,

        init_players = function()
            for _, psettings in pairs(global.players) do
                if psettings.mirrorConcrete == nil then
                    psettings.mirrorConcrete = true
                end
            end
        end,

        tiles = function()
            for tileName, prototype in pairs(game.tile_prototypes) do
                if prototype.items_to_place_this then
                    log("Tile: " .. tileName .." item: " .. next(prototype.items_to_place_this))
                end
            end
        end,

        add_entity_to_trigger = function()
            log("remote.call('farl', 'add_entity_to_trigger') is no longer supported. Listen to defines.events.script_raised_built and/or defines.events.script_raised_destroy instead.")
        end,

        remove_entity_from_trigger = function()
            log("remote.call('farl', 'remove_entity_from_trigger') is no longer supported. Listen to defines.events.script_raised_built and/or defines.events.script_raised_destroy instead.")
        end,

        get_trigger_list = function()
            log("remote.call('farl', 'get_trigger_list') is no longer supported. Listen to defines.events.script_raised_built and/or defines.events.script_raised_destroy instead")
        end,

        -- foo = function()
        --     local positions = {}
        --     local some_data = {whatever=10}
        --     log("concat start")
        --     for i = 0, 100 do
        --         for j = 0, 100 do
        --             positions[i..":"..j] = some_data.whatever + i
        --         end
        --     end
        --     log("concat stop")
        --     log(positions["0:0"])

        --     positions = {}
        --     log("hash start")
        --     for i = 0, 100 do
        --         for j = 0, 100 do
        --             positions[position_hash(i,j)] = some_data.whatever + i
        --         end
        --     end
        --     log("hash stop")
        --     log(positions["0:0"])
        -- end
    })