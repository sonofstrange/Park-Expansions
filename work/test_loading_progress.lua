local hooks,listeners,events={},{},{}
local wrapper={tInitSettings={sViewName="LoadingScreen"},IsReady=function()return true end,
 AddEventListener=function(_,name,count,callback)assert(count==0 or(name=="ParkExpansions_LoadingAck" and count==1));listeners[name]=callback end,
 TriggerEventAtNextAdvance=function(_,name,...)assert((name=="ParkExpansions_LoadProgress" or name=="ForgeUtils_AddImportHook") and select('#',...)==1);events[#events+1]=... end}
api={ui2={MapResources=function()end},world={GetWorldAPIs=function()error("Loading UI must not query uninitialized park APIs")end},forgeutils={uiHookManagerState={wrappers={[wrapper]="LoadingScreen"}}}}
local originalRequire=require
require=function(name)
 if name=="forgeutils.uihookmanager"then return{AddImportHook=function(_,view,path)assert(view=="HUD"or view=="LoadingScreen")end}end
 if name=="forgeutils.hookmanager"then return{AddHook=function(_,module,name,fn)hooks[module.."."..name]=fn end}end
 return originalRequire(name)
end
local R=assert(loadfile('work/boundarylab/Main/boundarylab.research.lua'))()
R.Init();assert(listeners.ParkExpansions_RequestLoadProgress and events[#events]=='[false,0,""]')
R.LoadingProgress(true,34.9,'Preparing "terrain"')
assert(events[#events]=='[true,34,"Preparing \\u0022terrain\\u0022"]')
local count=#events;R.LoadingProgress(true,34.9,'Preparing "terrain"');assert(#events==count)
listeners.ParkExpansions_RequestLoadProgress();assert(#events==count+1)
R.LoadingProgress(true,200,'Ready');assert(events[#events]=='[true,100,"Ready"]')
R.LoadingProgress(false,100,'Ready');assert(events[#events]=='[false,100,"Ready"]')
hooks["UI.GamefaceUIWrapper.Shutdown"](function()end,wrapper)
count=#events;R.LoadingProgress(true,12,'Next park');assert(#events==count)
print('PASS loading-view replay, single JSON payload, escaping, clamping, deduplication, shutdown and no park API access')

assert(hooks["UI.LoadingScreenUI.Init"]==nil and hooks["UI.LoadingScreenUI._OnReadyCallback"]==nil)
local called=false
local before=#events
local result=hooks["UI.LoadingScreenUI.Show"](function(self,animate,callback)called=true;assert(animate==true and callback=="native callback");return 42 end,wrapper,true,"native callback")
assert(called and result==42)
assert(events[#events]=='/js/boundarylab/loading.js')
assert(wrapper.tInitSettings.sViewAddress==nil,"Original loading page must remain untouched")
listeners.ParkExpansions_LoadingReady();listeners.ParkExpansions_LoadingAck(34)
print('PASS concrete Show imports the overlay after readiness, preserves native arguments and never replaces the loading page')
