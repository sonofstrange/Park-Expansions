-- A native AV inside GetWorldAPIs cannot be caught with pcall. Count attempts,
-- rather than accepting a Lua error as evidence that early access was safe.
local originalRequire=require
local calls=0
local allowNative=false
api={world={GetWorldAPIs=function()
    calls=calls+1
    assert(allowNative,"Native park lookup before original OnLoad")
    return {worldserialisation={RegisterWorldSerialisationClient=function()end},
        techtree={GetResearchPoints=function()return 0 end}}
end}}
local R=assert(loadfile('work/boundarylab/Main/boundarylab.research.lua'))()
R.LoadConfig=function(world)world.parkExpansionsConfig={ResearchEnabled=true}end
R.AutoConvert=function()end
R.PrepareMap=function(world)
    R.LoadingProgress(true,10,"Preparing original scenery")
    coroutine.yield()
    return true
end
local world={}
local loading=coroutine.create(function()R.BeforeLoad(world)end)
assert(coroutine.resume(loading))
assert(coroutine.status(loading)=='suspended')
R.Push();R.Report();R.Request('width',1)
assert(calls==0,"An early native lookup was attempted even though its error was caught")
allowNative=true
assert(coroutine.resume(loading))
assert(coroutine.status(loading)=='dead' and calls==1)
R.Push();assert(calls==1,"Native loader has not completed yet")
R.AfterLoad(world,{})
-- AfterLoad also queries terrain bounds to detect an existing 4K park.
assert(world.parkExpansionsParkReady and calls>=2)
print('PASS all HUD callbacks avoid native park access while terrain preparation or native loading is pending')
