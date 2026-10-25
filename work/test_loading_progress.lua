local hooks,listeners,events={},{},{}
local wrapper={tInitSettings={sViewName="LoadingScreen"},IsReady=function()return true end,
 AddEventListener=function(_,name,count,callback)assert(count==0 or(name=="ParkExpansions_LoadingAck" and count==1));listeners[name]=callback end,
 TriggerEventAtNextAdvance=function(_,name,...)assert(name=="ParkExpansions_LoadProgress" and select('#',...)==1);events[#events+1]=... end}
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
hooks["UI.LoadingScreenUI.Shutdown"](function()end,wrapper)
count=#events;R.LoadingProgress(true,12,'Next park');assert(#events==count)
print('PASS loading-view replay, single JSON payload, escaping, clamping, deduplication, shutdown and no park API access')

local settings={sViewName="LoadingScreen",sViewAddress="coui://UIGameface/LoadingScreen.html",nViewDepth=10,bStartEnabled=true,fnOnReadyCallback=function()end}
local seen
local result=hooks["UI.LoadingScreenUI.Init"](function(self,value)seen=value;return 42 end,{},settings)
assert(result==42 and seen~=settings)
assert(seen.sViewAddress=="coui://UIGameface/boundarylab/LoadingScreen.html")
assert(settings.sViewAddress=="coui://UIGameface/LoadingScreen.html" and seen.nViewDepth==10 and seen.fnOnReadyCallback==settings.fnOnReadyCallback)
local unchanged={sViewName="HUD",sViewAddress="original"}
hooks["UI.LoadingScreenUI.Init"](function(self,value)assert(value==unchanged)end,{},unchanged)
local nextView={tInitSettings=seen,IsReady=wrapper.IsReady,AddEventListener=wrapper.AddEventListener,TriggerEventAtNextAdvance=wrapper.TriggerEventAtNextAdvance}
hooks["UI.LoadingScreenUI._OnReadyCallback"](function()return 42 end,nextView)
listeners.ParkExpansions_LoadingReady();listeners.ParkExpansions_LoadingAck(34)
print('PASS concrete loading subclass routes a direct entry page, preserves native settings and binds readiness/ack events')
