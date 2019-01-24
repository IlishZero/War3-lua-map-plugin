local jass = require 'jass.common'
local japi = require 'jass.japi'
local slk = require 'jass.slk'
local dbg = require 'jass.debug'
local attribute = require 'ac.unit.attribute'
local restriction = require 'ac.unit.restriction'
local attack = require 'ac.attack'
local mover = require 'ac.mover'
local skill = require 'ac.skill'
local ORDER = require 'ac.war3.order'

local All = {}
local UNIT_LIST = ac.list()
local IdMap

local function getIdMap()
    if IdMap then
        return IdMap
    end
    IdMap = {}
    for name, data in pairs(ac.table.unit) do
        local id = ('>I4'):unpack(data.id)
        local obj = slk.unit[id]
        if not obj then
            log.error(('单位[%s]的id[%s]无效'):format(name, id))
            goto CONTINUE
        end
        IdMap[id] = name
        ::CONTINUE::
    end
    return IdMap
end

local function update(delta)
    for u in UNIT_LIST:pairs() do
        if u._dead then
            -- 如果单位死亡后被魔兽移除，则在Lua中移除
            if jass.GetUnitTypeId(u._handle) == 0 then
                u:remove()
                goto CONTINUE
            end
        end
        if u.class == '生物' and not u._dead then
            local life = delta * u:get '生命恢复'
            if life > 0 then
                u:add('生命', life)
            end
            local mana = delta * u:get '魔法恢复'
            if mana > 0 then
                u:add('魔法', mana)
            end
        end
        ::CONTINUE::
    end
    UNIT_LIST:clean()
end

local function createDestructor(unit, callback)
    if not unit._destructor then
        unit._destructor = {}
        unit._destructorIndex = 0
    end
    local function destructor()
        -- 保证每个析构器只调用一次
        if not unit._destructor[destructor] then
            return
        end
        unit._destructor[destructor] = nil
        callback()
    end
    local index = unit._destructorIndex + 1
    unit._destructor[destructor] = index
    unit._destructorIndex = index
    return destructor
end

local function onRemove(unit)
    -- 解除玩家英雄
    if unit:isHero() then
        unit._owner:removeHero(unit)
    end

    -- 执行析构器
    local destructors = unit._destructor
    if destructors then
        -- 保证所有人都按固定的顺序执行
        local list = {}
        for f in pairs(destructors) do
            list[#list+1] = f
        end
        table.sort(list, function (a, b)
            return destructors[a] < destructors[b]
        end)
        for _, f in ipairs(list) do
            f()
        end
    end
end

local function initType(data)
    local types = {}
    if ac.isString(data) then
        types[data] = true
    elseif ac.isTable(data) then
        for _, tp in ipairs(data) do
            if ac.isString(tp) then
                types[tp] = true
            end
        end
    end
    return types
end

local function create(player, name, point, face)
    local data = ac.table.unit[name]
    if not data then
        log.error(('单位[%s]不存在'):format(name))
        return nil
    end
    local x, y = point:getXY()
    local unitid = ac.id[data.id]
    local handle = jass.CreateUnit(player._handle, unitid, x, y, face)
    if handle == 0 then
        log.error(('单位[%s]创建失败'):format(name))
        return nil
    end
    local unit = ac.unit(handle)
    return unit
end

local mt = {}
function ac.unit(handle)
    if handle == 0 then
        return nil
    end
    if All[handle] then
        return All[handle]
    end

    local idMap = getIdMap()

    local id = jass.GetUnitTypeId(handle)
    local name = idMap[id]
    if not name then
        log.error(('ID[%s]对应的单位不存在'):format(id))
        return nil
    end
    local data = ac.table.unit[name]
    if not data then
        log.error(('名字[%s]对应的单位不存在'):format(name))
        return nil
    end
    local class = data.class
    if class ~= '弹道' and class ~= '生物' then
        log.error(('[%s]的class无效'):format(name))
        return nil
    end
    local slkUnit = slk.unit[id]

    local u = setmetatable({
        class = class,
        _gchash = handle,
        _handle = handle,
        _id = ac.id[id],
        _name = name,
        _data = data,
        _slk = slkUnit,
        _level = jass.GetUnitLevel(handle),
        _owner = ac.player(jass.GetOwningPlayer(handle)),
        _collision = ac.toNumber(slkUnit.collision),
    }, mt)
    dbg.gchash(u, handle)
    dbg.handle_ref(handle)
    u._gchash = handle

    All[handle] = u
    UNIT_LIST:insert(u)

    if class == '生物' then
        -- 初始化单位属性
        u._attribute = attribute(u, u._data.attribute)
        -- 初始化行为限制
        u._restriction = restriction(u, u._data.restriction)
        -- 初始化单位类型
        u._type = initType(u._data.type)

        u:eventNotify('单位-初始化', u)

        -- 初始化攻击
        u._attack = attack(u, u._data.attack)
        -- 初始化技能
        u._skill = skill(u)
        -- 添加命令图标
        u:addSkill('@命令', '技能')
        -- 设置为玩家的英雄
        if u:isHero() then
            u._owner:addHero(u)
        end

        u:eventNotify('单位-创建', u)
    elseif class == '弹道' then
        jass.UnitAddAbility(handle, ac.id.Aloc)
    end

    return u
end

mt.__index = mt

mt.type = 'unit'

function mt:__tostring()
    return ('{unit|%s|%s}'):format(self:getName(), self._handle)
end

function mt:getName()
    return self._name
end

function mt:set(k, v)
    if not self._attribute then
        return
    end
    self._attribute:set(k, v)
end

function mt:get(k)
    if not self._attribute then
        return 0.0
    end
    return self._attribute:get(k)
end

function mt:add(k, v)
    if not self._attribute then
        return
    end
    return self._attribute:add(k, v)
end

function mt:addRestriction(k)
    if not self._restriction then
        return
    end
    return self._restriction:add(k)
end

function mt:removeRestriction(k)
    if not self._restriction then
        return
    end
    self._restriction:remove(k)
end

function mt:getRestriction(k)
    if not self._restriction then
        return 0
    end
    return self._restriction:get(k)
end

function mt:hasRestriction(k)
    if not self._restriction then
        return false
    end
    self._restriction:has(k)
end

function mt:isAlive()
    if self._removed then
        return false
    end
    if self._dead then
        return false
    end
    return true
end

function mt:isHero()
    if self._hero == nil then
        -- 通过检查单位id的第一个字母是否为大写决定是否是英雄
        local char = self._id:sub(1, 1)
        local code = char:byte()
        self._hero = code >= 65 and code <= 90
    end
    return self._hero
end

function mt:kill(target)
    if not ac.isUnit(target) then
        return
    end
    if target._dead then
        return
    end
    local handle = target._handle
    target._lastPoint = target:getPoint()
    target._dead = true
    jass.KillUnit(handle)
    target:set('生命', 0)
    target:eventNotify('单位-死亡', target, self)
end

function mt:remove()
    if self._removed then
        return
    end
    self._removed = true
    if not self._dead then
        self:kill(self)
    end
    local handle = self._handle
    All[handle] = nil
    UNIT_LIST:remove(self)
    jass.RemoveUnit(handle)
    onRemove(self)

    self._handle = 0
    dbg.handle_unref(handle)
end

function mt:getPoint()
    if self._lastPoint then
        return self._lastPoint
    end
    -- 以后进行优化：在每帧脚本控制时间内，第一次获取点后将点缓存下来
    return ac.point(jass.GetUnitX(self._handle), jass.GetUnitY(self._handle))
end

function mt:setPoint(point)
    if self._removed then
        return false
    end
    local x, y = point:getXY()
    jass.SetUnitX(self._handle, x)
    jass.SetUnitY(self._handle, y)
    if self._lastPoint then
        self._lastPoint = point
    end
    return true
end

function mt:blink(point)
    if not self:isAlive() then
        return false
    end
    if not self:setPoint(point) then
        return false
    end
    return true
end

function mt:getOwner()
    return self._owner
end

function mt:setOwner(player, changeColor)
    if player == self._owner then
        return false
    end
    if not ac.isPlayer(player) then
        return false
    end
    jass.SetUnitOwner(self._handle, player._handle, ac.toBoolean(changeColor))
    local newOwner = ac.player(jass.GetOwningPlayer(self._handle))
    if newOwner == self._owner then
        return false
    end
    self._owner = newOwner
    return true
end

function mt:particle(model, socket)
    local handle = jass.AddSpecialEffectTarget(model, self._handle, socket)
    if handle == 0 then
        return nil
    else
        return createDestructor(self, function ()
            -- 这里不做引用计数保护，但析构器会保证这段代码只会运行一次
            jass.DestroyEffect(handle)
        end)
    end
end

function mt:setFacing(angle, time)
    if time then
        jass.SetUnitFacingTimed(self._handle, angle, time)
    else
        japi.EXSetUnitFacing(self._handle, angle)
    end
end

function mt:getFacing()
    return jass.GetUnitFacing(self._handle)
end

function mt:createUnit(name, point, face)
    return create(self:getOwner(), name, point, face)
end

function mt:addHeight(n)
    if n == 0.0 then
        return
    end
    if not self._height then
        self._height = 0.0
        jass.UnitAddAbility(self._handle, ac.id.Arav)
        jass.UnitRemoveAbility(self._handle, ac.id.Arav)
    end
    self._height = self._height + n
    jass.SetUnitFlyHeight(self._handle, self._height, 0.0)
end

function mt:getHeight()
    return self._height or 0.0
end

function mt:getCollision()
    return self._collision
end

function mt:addSkill(name, type, slot)
    if self._removed then
        return nil
    end
    if not self._skill then
        return nil
    end
    return self._skill:addSkill(name, type, slot)
end

function mt:findSkill(name, type)
    if self._removed then
        return nil
    end
    if not self._skill then
        return nil
    end
    return self._skill:findSkill(name, type)
end

function mt:eachSkill(tp)
    if not self._skill then
        return function () end
    end
    return self._skill:eachSkill(tp)
end

function mt:stopCast()
end

function mt:_stopCastByClient()
end

function mt:event(name, f)
    return ac.eventRegister(self, name, f)
end

function mt:eventDispatch(name, ...)
    local res = ac.eventDispatch(self, name, ...)
    if res ~= nil then
        return res
    end
    local res = self:getOwner():eventDispatch(name, ...)
    if res ~= nil then
        return res
    end
    return nil
end

function mt:eventNotify(name, ...)
    ac.eventNotify(self, name, ...)
    self:getOwner():eventNotify(name, ...)
end

function mt:moverTarget(data)
    if self._removed then
        return nil
    end
    data.source = self
    data.moverType = 'target'
    return mover.create(data)
end

function mt:moverLine(data)
    if self._removed then
        return nil
    end
    data.source = self
    data.moverType = 'line'
    return mover.create(data)
end

function mt:walk(target)
    if self._removed then
        return false
    end
    if ac.isPoint(target) then
        local x, y = target:getXY()
        return jass.IssuePointOrderById(self._handle, ORDER['move'], x, y)
    elseif ac.isUnit(target) then
        if not target:isAlive() then
            return false
        end
        return jass.IssueTargetOrderById(self._handle, ORDER['move'], target._handle)
    end
    log.error('walk的目标必须是点或单位')
    return false
end

function mt:attack(target)
    if self._removed then
        return false
    end
    if ac.isPoint(target) then
        local x, y = target:getXY()
        return jass.IssuePointOrderById(self._handle, ORDER['attack'], x, y)
    elseif ac.isUnit(target) then
        if not target:isAlive() then
            return false
        end
        return jass.IssueTargetOrderById(self._handle, ORDER['attack'], target._handle)
    end
    log.error('attack的目标必须是点或单位')
    return false
end

function mt:reborn(point, showEffect)
    if not self:isHero() then
        return false
    end
    if not ac.isPoint(point) then
        return false
    end
    local x, y = point:getXY()
    local suc = jass.ReviveHero(self._handle, x, y, ac.toBoolean(showEffect))
    if suc then
        self._dead = false
        self:set('生命', self:get '生命上限')
        local mana = self:get '魔法'
        self:set('魔法', 0.0)
        self:set('魔法', mana)
        self:eventNotify('单位-复活', self)
    end
    return suc
end

function mt:slk(key)
    return self._slk[key]
end

function mt:_onLevel()
    while true do
        local newLevel = jass.GetUnitLevel(self._handle)
        if self._level < newLevel then
            self._level = self._level + 1
            self:eventNotify('单位-升级', self)
        else
            break
        end
    end
end

function mt:level(lv, show)
    if ac.isInteger(lv) then
        if lv > self._level then
            jass.SetHeroLevel(self._handle, lv, ac.toBoolean(show))
        elseif lv < self._level then
            jass.UnitStripHeroLevel(self._handle, self._level - lv)
            while true do
                local newLevel = jass.GetUnitLevel(self._handle)
                if self._level > newLevel then
                    self._level = self._level - 1
                    self:eventNotify('单位-降级', self)
                else
                    break
                end
            end
        end
    else
        return self._level
    end
end

function mt:exp(exp, show)
    if ac.isInteger(exp) then
        jass.SetHeroXP(self._handle, exp, ac.toBoolean(show))
    else
        return jass.GetHeroXP(self._handle)
    end
end

function mt:addExp(exp, show)
    if ac.isInteger(exp) then
        jass.AddHeroXP(self._handle, exp, ac.toBoolean(show))
    end
end

function mt:currentSkill()
    if not self._skill then
        return nil
    end
    return self._skill:currentSkill()
end

function mt:isInRange(point, radius)
    if not ac.isPoint(point) then
        return
    end
    if not ac.isNumber(radius) then
        return
    end
    return self:getPoint() * point <= self._collision + radius
end

function mt:isEnemy(other)
    if ac.isPlayer(other) then
        return jass.IsPlayerEnemy(self._owner._handle, other._handle)
    elseif ac.isUnit(other) then
        return jass.IsPlayerEnemy(self._owner._handle, other._owner._handle)
    end
    return false
end

function mt:isAlly(other)
    if ac.isPlayer(other) then
        return jass.IsPlayerEnemy(self._owner._handle, other._handle)
    elseif ac.isUnit(other) then
        return jass.IsPlayerEnemy(self._owner._handle, other._owner._handle)
    end
    return false
end

function mt:isBuilding()
    return self._slk.isbldg == 1
end

function mt:isIllusion()
    return jass.IsUnitIllusion(self._handle)
end

function mt:isType(name)
    if not self._type then
        return false
    end
    if self._type[name] then
        return true
    else
        return false
    end
end

function mt:addType(name)
    if not self._type then
        return
    end
    if ac.isString(name) then
        self._type[name] = true
    end
end

function mt:removeType(name)
    if not self._type then
        return
    end
    if name ~= nil then
        self._type[name] = nil
    end
end

function mt:isVisible(other)
    if ac.isUnit(other) then
        return jass.IsUnitVisible(other._handle, self._owner._handle)
    else
        return false
    end
end

return {
    list = UNIT_LIST,
    update = update,
    create = create,
}
