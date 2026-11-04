-- Reproduces the exact stock translation clamp verified in the installed Lua
-- bytecode. Exercise the hooks without a game process or placement commits.
local originalRequire=require
local hooks={}
local function vec(x,y,z)
    return {GetX=function()return x end,GetY=function()return y end,GetZ=function()return z end}
end
local lower,upper=vec(-2048,-2304,-2048),vec(2047,2303,2047)
local calls=0
api={world={GetWorldAPIs=function()return {voxelterrain={
    GetPrimaryVoxelTerrainEntityID=function()return 42 end,
    GetWorldBounds=function(_,id)assert(id==42);calls=calls+1;return lower,upper end}}end}}
require=function(name)
    if name=='forgeutils.hookmanager' then return {AddHook=function(_,module,method,fn)
        hooks[module..'.'..method]=fn end}end
    return originalRequire(name)
end
local R=assert(loadfile('work/boundarylab/Main/boundarylab.research.lua'))()
R.InstallAdvancedMoveFix();require=originalRequire
local clampHook=assert(hooks['Common.MathUtils.ClampV3'])
local stockMin,stockMax=vec(-1000,-1000,-1000),vec(1000,1000,1000)
local function stockClamp(p,a,b)
    local function clamp(v,low,high)return math.max(low,math.min(v,high))end
    return vec(clamp(p:GetX(),a:GetX(),b:GetX()),clamp(p:GetY(),a:GetY(),b:GetY()),clamp(p:GetZ(),a:GetZ(),b:GetZ()))
end
local function clamp(p,a,b)return clampHook(stockClamp,p,a or stockMin,b or stockMax)end
local function equal(v,x,y,z)assert(v:GetX()==x and v:GetY()==y and v:GetZ()==z,'Wrong translation bounds')end
-- Establish current world without map generation or save access.
R.LoadConfig=function()end;R.BackupNormalPark=function()end;R.PrepareMap=function()return true end
R.AutoConvert=function()end;R.ReadConvertedSave=function()end
local world={boundaryLabResearch={managed=true}}
R.BeforeLoad(world);world.parkExpansionsParkReady=true
local point=vec(1600,1800,-1700)
equal(clamp(point),1000,1000,-1000)
print('PASS reproduced stock +/-1000 clamp; ordinary math remains unchanged')
local methods={
 'Editors.Scenery.Utils.DraggableWidgets._StepDragAxisTranslate',
 'Editors.Scenery.Utils.DraggableWidgets._StepDragPlaneTranslate',
 'Editors.Scenery.Utils.AxisPositioning._Update_AlongNormal',
 'Editors.Scenery.Utils.AxisPositioning._Update_AlongSurfaceAxis'}
for _,name in ipairs(methods)do
    local hook=assert(hooks[name])
    local a,b,c=hook(function(self,input)assert(self=='editor' and input=='mouse-or-gamepad');return nil,clamp(point),'snap-kept'end,'editor','mouse-or-gamepad')
    assert(a==nil and c=='snap-kept');equal(b,1600,1800,-1700)
    equal(hook(function()return clamp(vec(3000,3000,-3000))end,{}),2047,2303,-2048)
end
assert(calls==8)
print('PASS axis/plane and normal/surface translation use actual 4K bounds; nil and multiple returns preserved')
local axis=hooks[methods[1]]
axis(function()
    equal(clamp(point,vec(-10,-10,-10),vec(10,10,10)),10,10,-10)
end,{})
equal(clamp(point),1000,1000,-1000)
print('PASS non-movement and non-stock clamp limits remain unchanged')
for _,kind in ipairs({'unmanaged','loading','missing-terrain'})do
    world.boundaryLabResearch.managed=kind~='unmanaged'
    world.parkExpansionsParkReady=kind~='loading'
    if kind=='missing-terrain' then lower=nil end
    equal(axis(function()return clamp(point)end,{}),1000,1000,-1000)
end
world.boundaryLabResearch.managed=true;world.parkExpansionsParkReady=true
lower,upper=vec(-1024,-2304,-1024),vec(1023,2303,1023)
equal(axis(function()return clamp(point)end,{}),1023,1800,-1024)
print('PASS vanilla/loading/error fallback and actual 2K terrain bounds')
lower,upper=vec(-2048,-2304,-2048),vec(2047,2303,2047)
local ok,message=pcall(axis,function()error('translation failed')end,{})
assert(not ok and message:find('translation failed',1,true));equal(clamp(point),1000,1000,-1000)
axis(function()
    local nestedOK=pcall(axis,function()error('nested failure')end,{})
    assert(not nestedOK);equal(clamp(point),1600,1800,-1700)
end,{})
equal(clamp(point),1000,1000,-1000)
local co=coroutine.create(function()
    axis(function()coroutine.yield();equal(clamp(point),1600,1800,-1700)end,{})
end)
assert(coroutine.resume(co));equal(clamp(point),1000,1000,-1000)
assert(coroutine.resume(co));assert(coroutine.status(co)=='dead')
print('PASS translation errors, nested scopes and coroutine isolation restore ordinary clamps')
