-- Regression for the stock 1000 m terrain-relative height ray and its UI fallback.
local originalRequire=require
local hook
local metavec={__unm=function(v)return setmetatable({y=-v.y,GetY=v.GetY},getmetatable(v))end}
local function vec(y)return setmetatable({y=y,GetY=function(self)return self.y end},metavec)end
local V={YAxis=vec(1)}
local units=1
local conversion={Distance_Metres='m',Distance_ToUserPref=function(n,unit)assert(unit=='m');return n*units end}
local rays={}
local terrain={GetPrimaryVoxelTerrainEntityID=function()return 71 end,GetWorldBounds=function()return vec(-2304),vec(2303)end,
 CoarseRayCast=function(_,id,position,direction,depth)
  assert(id==71 and direction.y==-1);rays[#rays+1]=depth
  if position.noGround or position.height>depth then return nil end
  return position.height
 end}
api={world={GetWorldAPIs=function()return{voxelterrain=terrain}end}}
require=function(name)
 if name=='forgeutils.hookmanager' then return {AddHook=function(_,module,method,fn)
  assert(module=='Editors.Track.TrackHeightMarkerHelper' and method=='UpdateHeightMarkers');hook=fn end}end
 if name=='Vector3' then return V end
 if name=='Helpers.UnitConversion' then return conversion end
 return originalRequire(name)
end
local R=assert(loadfile('work/boundarylab/Main/boundarylab.research.lua'))()
R.InstallHeightMarkerFix();assert(hook)
local displayed,pointsOut={},nil
local manager={SetBillboardWidgetUIInfo=function(_,kind,index,info)
 assert(kind==17);displayed[index]={nValue=info.nValue,sValueType=info.sValueType,nOpacity=info.nOpacity}end,
 SetBillboardWidgetData=function(_,kind,positions)assert(kind==17);pointsOut=positions end}
local helper={billboardUIManager=manager,nCoasterLabelWidgetID=17,sHeightMarkerMode='hm_terrainrelative'}
local positions={}
for _,h in ipairs({0,999,1000,1001,1500,2048})do local p=vec(h+100);p.height=h;positions[#positions+1]=p end
local miss=vec(2200);miss.height=2200;miss.noGround=true;positions[#positions+1]=miss
-- Mirrors the verified original marker producer: hardcoded CoarseRayCast(...,1000),
-- conversion of a miss to 0, and SetUIInfo before SetWidgetData.
local function stock(self,heatmap,sea)
 for i,p in ipairs(positions)do
  local height=terrain:CoarseRayCast(71,p,-V.YAxis,1000)
  self.billboardUIManager:SetBillboardWidgetUIInfo(17,i,{nValue=height and conversion.Distance_ToUserPref(height,'m')or 0,sValueType='Distance',nOpacity=.5})
 end
 self.billboardUIManager:SetBillboardWidgetData(17,positions)
 return 'stock-result'
end
stock(helper,false,0)
assert(displayed[3].nValue==1000 and displayed[4].nValue==0 and displayed[6].nValue==0)
print('PASS reproduced stock zero labels beyond the 1000 m ray')
assert(hook(stock,helper,false,0)=='stock-result')
for i,h in ipairs({0,999,1000,1001,1500,2048,0})do
 assert(displayed[i].nValue==h,'incorrect marker '..i)
 assert(displayed[i].sValueType=='Distance' and displayed[i].nOpacity==.5)
end
assert(helper.billboardUIManager==manager and pointsOut==positions)
print('PASS actual heights above 1000 m, ordinary values and genuine no-ground zeros')
units=3.28084;hook(stock,helper,false,0)
assert(math.abs(displayed[6].nValue-2048*units)<.01)
print('PASS existing metres/feet preference and widget styling retained')
for _,case in ipairs({{'hm_off',false},{'hm_sealevel',false},{'hm_terrainrelative',true}})do
 helper.sHeightMarkerMode=case[1]
 assert(hook(function(self,h,s)assert(self.billboardUIManager==manager and h==case[2]and s==42);return 91 end,helper,case[2],42)==91)
end
print('PASS disabled, heatmap and sea-level modes delegate unchanged')
helper.sHeightMarkerMode='hm_terrainrelative'
local ok,message=pcall(hook,function()error('producer failed')end,helper,false,0)
assert(not ok and message:find('producer failed')and helper.billboardUIManager==manager)
print('PASS original UI manager restored even when marker production fails')
require=originalRequire
