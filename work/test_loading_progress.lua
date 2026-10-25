-- Reproduce the context restriction omitted by the earlier UI mocks.
local hooks,listeners,events={},{},{}
local loadingContext=false
local ready=true
local wrapper={view="native-view",tInitSettings={sViewName="LoadingScreen",sViewAddress="coui://UIGameface/LoadingScreen.html"},
 IsReady=function()assert(loadingContext,"Readiness queried from park-loading context");return ready end,
 AddEventListener=function(_,name,count,callback)
  assert(loadingContext,"Native registration from park-loading context")
  assert(count==0 or(name=="ParkExpansions_LoadingAck"and count==1));listeners[name]=callback
 end,
 TriggerEventAtNextAdvance=function(_,name,...)
  assert(loadingContext,"Native UI event sent from park-loading context")
  assert(select('#',...)==1,"Native event must have one payload")
  events[#events+1]={name,...}
 end}
local phaseCalls=0
local environment={OnPhase=function(self,name,cached,dt)assert(self==environment or self.OnPhase);phaseCalls=phaseCalls+1;return 42 end}
local worldCalls=0
api={game={GetEnvironment=function()return environment end},ui2={MapResources=function()end},world={
 GetWorldAPIs=function()worldCalls=worldCalls+1;error("Uninitialized park APIs queried")end,
 IsLoaded=function()worldCalls=worldCalls+1;error("Global loading tick must not resolve worlds")end,
 GetScript=function()worldCalls=worldCalls+1;error("Global loading tick must not resolve world scripts")end}}
local originalRequire=require
require=function(name)
 if name=="forgeutils.uihookmanager"then return{AddImportHook=function(_,view,path)assert(view=="HUD")end}end
 if name=="forgeutils.hookmanager"then return{AddHook=function(_,module,name,fn)hooks[module.."."..name]=fn end}end
 return originalRequire(name)
end
local R=assert(loadfile('work/boundarylab/Main/boundarylab.research.lua'))()
R.Init();assert(#events==0)
local captured=hooks["UI.LoadingScreenUI.new"](function(class,callback)
 assert(class=="LoadingScreenUI" and callback=="native-ready");return wrapper
end,"LoadingScreenUI","native-ready")
assert(captured==wrapper and #events==0,"View capture changed constructor behavior or called native UI")
assert(hooks["UI.LoadingScreenUI.Init"]==nil and hooks["UI.LoadingScreenUI.Show"]==nil)
local count=0
local function tick()
 loadingContext=true
 local value=environment:OnPhase("Advance",true,0.016);count=count+1
 loadingContext=false;assert(value==42)
end
tick();assert(#events==0,"Idle loading view imported native UI")
R.LoadingProgress(true,0,"Preparing terrain")
assert(#events==0,"Park load touched UI")
tick();assert(events[1][1]=="ForgeUtils_AddImportHook"and events[1][2]=="/js/boundarylab/loading.js")
local function last()return events[#events][2]end
assert(last()=='[true,0,"Preparing terrain"]')
local before=#events
local park=coroutine.create(function()
 R.LoadingProgress(true,34.9,'Preparing "terrain"');coroutine.yield()
 R.LoadingProgress(true,61,'Converting park');coroutine.yield()
 R.LoadingProgress(false,100,'Done')
end)
assert(coroutine.resume(park));assert(#events==before)
tick();assert(last()=='[true,34,"Preparing \\u0022terrain\\u0022"]')
before=#events
listeners.ParkExpansions_LoadingReady();listeners.ParkExpansions_RequestLoadProgress();listeners.ParkExpansions_LoadingAck(34)
assert(#events==before,"UI callback re-entered native UI dispatch")
tick();assert(#events==before+1)
assert(coroutine.resume(park));tick();assert(last()=='[true,61,"Converting park"]')
assert(coroutine.resume(park));tick();assert(last()=='[false,100,"Done"]')
before=#events;tick();assert(#events==before,"Unchanged frame sent another payload")
hooks["UI.LoadingScreenUI.Shutdown"](function(self)
 assert(self==wrapper);self.view=nil
end,wrapper)
R.LoadingProgress(true,10,"Next map");tick();assert(#events==before,"Destroyed view was used")
wrapper.view="replacement-view"
hooks["UI.LoadingScreenUI.new"](function()return wrapper end)
ready=false;tick();assert(#events==before)
hooks["UI.LoadingScreenUI.Shutdown"](function(self)self.view=nil end,wrapper)
wrapper.view="registry-view"
api.forgeutils={uiHookManagerState={wrappers={[wrapper]="LoadingScreen"}}}
ready=true;tick();assert(#events>before,"Existing ForgeUtils loading view was not captured")
assert(last()=='[true,10,"Next map"]')
assert(worldCalls==0,"Uninitialized native world APIs were queried")
assert(wrapper.tInitSettings.sViewAddress=="coui://UIGameface/LoadingScreen.html")
assert(environment.parkExpansionsLoadingDriver and phaseCalls==count)
print('PASS captured loading-view lifecycle, no native world lookups, pure capture/callbacks, shutdown invalidation and unchanged phase behavior')
