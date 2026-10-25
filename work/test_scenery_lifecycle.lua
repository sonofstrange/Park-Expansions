-- Actual world hooks must not create editable previews during OnLoad/OnActivate.
local nativeRequire=require
local busy=false
local apiCalls=0
api={debug={Trace=function()end},undo={IsBusy=function()apiCalls=apiCalls+1;return busy end}}
local S=assert(loadfile("work/boundarylab/Main/boundarylab.scenery.lua"))()
local world={parkExpansionsScenery={complete=false}}
local creates=0
S.AfterLoad=function(self)
    assert(self==world)
    creates=creates+1
    coroutine.yield()
end
assert(S.Advance(world,function()end)==false and apiCalls==0)
S.Queue(world)
assert(creates==0 and apiCalls==0,"Queue touched native editor")
world.fnGenerateSpawnPoint=coroutine.create(function()end)
assert(S.Advance(world,function()end) and creates==0 and apiCalls==0,"Import overlapped default entrance placement")
world.fnGenerateSpawnPoint=nil;busy=true
assert(S.Advance(world,function()end) and creates==0)
busy=false
assert(S.Advance(world,function()end) and creates==1 and world.parkExpansionsSceneryTask)
assert(S.Advance(world,function()end) and world.parkExpansionsSceneryTask==nil)
assert(S.Advance(world,function()end)==false and creates==1)
world.parkExpansionsScenery.complete=true
S.Queue(world);assert(not world.parkExpansionsSceneryPending)

local cancelled,reactivated,resumed=0,0,0
api.undo.CancelPreview=function(value)assert(value==23);cancelled=cancelled+1 end
api.world={GetWorldAPIs=function()return {park={ActivateParkEditConstraints=function()reactivated=reactivated+1 end}}end}
world.parkExpansionsSceneryPreview=23
world.parkExpansionsSceneryConstraints=true
world.parkExpansionsScenerySaveControl={ResumeSave=function()resumed=resumed+1 end}
S.Shutdown(world)
assert(cancelled==1 and reactivated==1 and resumed==1)
S.Shutdown(world)
assert(cancelled==1 and reactivated==1 and resumed==1,"Shutdown released native operation twice")

local order={}
local R={Progress=function()end}
local scenery={Queue=function(self)order[#order+1]="queue" end,
 Advance=function(self)order[#order+1]="scenery";return true end,Shutdown=function()end}
require=function(name)
 if name=="boundarylab.research" then return R end
 if name=="boundarylab.scenery" then return scenery end
 return nativeRequire(name)
end
local nativeIO=io;io=nil
local M=assert(loadfile("work/boundarylab/Main/database.mod_boundarylabluadatabase.lua"))()
local module={OnActivate=function(self,arg)assert(arg=="native");order[#order+1]="activate";return 77 end,
 OnAdvance=function()order[#order+1]="advance"end,OnLoad=function()end}
M.AddLuaHooks(function(name,hook)assert(name=="Worlds.CPTWorld");hook(module)end)
assert(module.OnActivate(world,"native")==77)
assert(table.concat(order,",")=="activate,queue")
module.OnAdvance(world,0.016)
assert(table.concat(order,",")=="activate,queue,advance,scenery")
require=nativeRequire;io=nativeIO
print("PASS no scenery creation before activation; native entrance/editor waits; one coroutine; native Advance runs first")
