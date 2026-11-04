-- Read-only gate diagnostics: no placement, graph rebuild, or history operations.
local originalRequire=require
local function vec(x,y,z)
 return {GetX=function()return x end,GetY=function()return y end,GetZ=function()return z end}
end
local pending=false
local reads=0
local gates=0
local w={ridestation={RideGateType_Entrance=1,
 GetAllStations=function()return {100,200}end,
 GetRideGateEntity=function(_,id,kind)assert(kind==1);gates=gates+1;return id+1 end,
 HasConnectedQueue=function(_,id,kind)assert(kind==1);return id==100 end},
 volumes={GetNavPartFromRay=function(_,point,direction)
  assert(direction:GetY()==-1)
  return {IsQueue=function()return true end},vec(point:GetX(),point:GetY()-4,point:GetZ())
 end}}
api={crowdsimulation={ArePathSectionsPending=function()return pending end,
 IsPointOnPath=function(point,relaxed)
  reads=reads+1;assert(type(relaxed)=='boolean')
  return point:GetX()~=598,nil,false
 end},transform={CalculateWorldTransform=function(id)
 return {GetPos=function()return vec(id==101 and 0 or 600,10,0)end,GetF=function()return vec(1,0,0)end}
 end}}
require=function(name)if name=='Vector3' then return {new=function(_,x,y,z)return vec(x,y,z)end}end;return originalRequire(name)end
local R=assert(loadfile('work/boundarylab/Main/boundarylab.research.lua'))()
local report=R.NavigationReport(w)
assert(report:find('outside_vanilla=true',1,true))
assert(report:find('outside_vanilla=false',1,true))
assert(report:find('queue_connected=false',1,true))
assert(report:find('STATIONS=2 PROBES=12 MISMATCHES=1',1,true))
assert(reads==24 and gates==2)
pending=true;reads=0;gates=0
assert(R.NavigationReport(w):find('pending',1,true));assert(reads==0 and gates==0)
pending=false
w.ridestation.GetAllStations=function()local ids={};for i=1,80 do ids[i]=100 end;return ids end
assert(R.NavigationReport(w):find('TRUNCATED=true',1,true));assert(gates==64)
assert(R.NavigationReport({})=='NAV_AUDIT=unavailable')
require=originalRequire
print('PASS read-only navigation audit: gate sides, queue/crowd mismatches, loading guard and bounded station count')
