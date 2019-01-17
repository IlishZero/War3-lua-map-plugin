local jass = require 'jass.common'
local japi = require 'jass.japi'
local unit = require 'ac.unit'

local MIN_ID = 1
local MAX_ID = 16
local LocalPlayer
local All
local mt = {}

local function init()
    All = {}
    for id = MIN_ID, MAX_ID do
        local handle = jass.Player(id - 1)
        local player = setmetatable({
            _handle = handle,
            _id = id,
            _hero = {}
        }, mt)
        All[id] = player
        All[handle] = player
    end
end

mt.__index = mt
mt.type = 'player'

function mt:addHero(unit)
    if self._hero[unit] then
        return false
    end
    self._hero[#self._hero+1] = unit
    self._hero[unit] = true
    return true
end

function mt:removeHero(unit)
    if not self._hero[unit] then
        return false
    end
    self._hero[unit] = nil
    for i, u in ipairs(self._hero) do
        if u == unit then
            table.remove(self._hero, i)
            return true
        end
    end
    return false
end

function mt:getHero(n)
    if n == nil then
        for _, hero in ipairs(self._hero) do
            if hero._owner == self then
                return hero
            end
        end
    else
        local hero = self._hero[n]
        if hero and hero._owner == self then
            return hero
        end
    end
    return nil
end

function mt:selectUnit(unit)
    if self == ac.localPlayer() then
        jass.ClearSelection()
        jass.SelectUnit(unit._handle, true)
    end
end

function mt:createUnit(name, point, face)
    return unit.create(self, name, point, face)
end

function mt:event(name, f)
    return ac.eventRegister(self, name, f)
end

function mt:eventDispatch(name, ...)
    local res = ac.eventDispatch(self, name, ...)
    if res ~= nil then
        return res
    end
    local res = ac.game:eventDispatch(ac.game, name, ...)
    if res ~= nil then
        return res
    end
    return nil
end

function mt:eventNotify(name, ...)
    ac.eventNotify(self, name, ...)
    ac.game:eventNotify(name, ...)
end

function mt:message(...)
    if type(...) == 'table' then
        local data = ...
        local x, y
        if data.position then
            x = ac.toNumber(data.position[1])
            y = ac.toNumber(data.position[2])
        else
            x = 0.0
            y = 0.0
        end
        local text = ac.formatText(data.text, data.data, data.color)
        local time = ac.toNumber(data.time, 10000.0)
        jass.DisplayTimedTextToPlayer(self._handle, x, y, time / 1000.0, text)
    else
        local text, time = ...
        jass.DisplayTimedTextToPlayer(self._handle, 0.0, 0.0, ac.toNumber(time, 10000.0) / 1000.0, tostring(text))
    end
end

function mt:chat(...)
    if self ~= ac.localPlayer() then
        return
    end
    local source, text, tp
    if type(...) == 'table' then
        local data = ...
        source = data.source
        text = ac.formatText(data.text, data.data, data.color)
        tp = data.type
    else
        source, text, tp = ...
        text = tostring(text)
    end
    if tp == '所有人' then
        tp = 0
    elseif tp == '盟友' then
        tp = 1
    elseif tp == '观看者' then
        tp = 2
    elseif tp == '所有人' then
        tp = 3
    else
        tp = 3
    end
    if ac.isPlayer(source) then
        japi.EXDisplayChat(source._handle, tp, text)
    else
        local dummyPlayer = ac.player(15)
        local name = jass.GetPlayerName(dummyPlayer._handle)
        jass.SetPlayerName(dummyPlayer._handle, ('|cffffffff%s|r'):format(source))
        japi.EXDisplayChat(dummyPlayer._handle, tp, text)
        jass.SetPlayerName(dummyPlayer._handle, name)
    end
end

function ac.player(id)
    if not All then
        init()
    end
    return All[id]
end

function ac.localPlayer()
    if not LocalPlayer then
        LocalPlayer = ac.player(jass.GetLocalPlayer())
    end
    return LocalPlayer
end
