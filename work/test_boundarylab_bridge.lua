local hooks,listeners={},{}
local captured
local wrapper={tInitSettings={sViewName="HUD"},IsReady=function()return true end,
    AddEventListener=function(_,name,count,callback)listeners[name]={count=count,callback=callback}end,
    TriggerEventAtNextAdvance=function(_,name,...)
        -- Match the verified native five-slot limit; 0.21 passed EIGHT here.
        assert(select('#',...)<=5,"Native event argument buffer overflow")
        assert(name=="BoundaryLab_State" and select('#',...)==1,"State must use one payload")
        captured=...
        assert(type(captured)=="string")
    end}
local w={techtree={GetResearchPoints=function()return 1234 end}}
api={world={GetWorldAPIs=function()return w end},ui2={MapResources=function(name)assert(name=="BoundaryLabUI")end}}
local originalRequire=require
require=function(name)
    if name=="forgeutils.uihookmanager" then return {AddImportHook=function(_,view,path)
        assert((view=="HUD" and path=="/js/boundarylab/research.js") or (view=="LoadingScreen" and path=="/js/boundarylab/loading.js"))end}end
    if name=="forgeutils.hookmanager" then return {AddHook=function(_,module,name,fn)
        if module=="UI.LoadingScreenUI"then return end
        assert(module=="UI.GamefaceUIWrapper");hooks[name]=fn end}end
    return originalRequire(name)
end
local R=assert(loadfile('work/boundarylab/Main/boundarylab.research.lua'))()
R.Init()
assert(hooks._OnReadyCallback(function()return 42 end,wrapper)==42)
assert(listeners.BoundaryLab_RequestState.count==0 and listeners.BoundaryLab_Purchase.count==2
    and listeners.BoundaryLab_Report.count==0)
listeners.BoundaryLab_RequestState.callback()
assert(captured:sub(1,1)=="[")
local world={}
R.BeforeLoad(world)
R.Progress(world,17.25,'Quote " and slash \\ and newline\ncontrol\1 and текст')
local file=assert(io.open('work/bridge-payload.json','wb'));file:write(captured);file:close()
hooks.Shutdown(function()end,wrapper)
captured=nil;R.Push();assert(captured==nil,"Retained a destroyed HUD wrapper")
require=originalRequire
print('PASS native five-slot event limit, single-payload state, listener lifecycle and escaping')
