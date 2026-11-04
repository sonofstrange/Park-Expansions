-- Background mode must never create gameplay parts, previews, or saved entities.
local nativeRequire,nativeLoadfile=require,loadfile
local function vector(x,y,z)
 return {x=x,y=y,z=z,GetX=function()return x end,GetY=function()return y end,GetZ=function()return z end}
end
local V={new=function(_,x,y,z)return vector(x,y,z)end}
local chunk=assert(nativeLoadfile('work/boundarylab/Main/boundarylab.scenery.lua'))
local saves,loads,ids,deleted={},nil,{},{}
local instantiated=0
local fail=false
api={debug={Trace=function()end},world={GetWorldAPIs=function()return {
 worldserialisation={RegisterWorldSerialisationClient=function(_,_,_,save,load)saves[#saves+1]=save;loads=load end},
 voxelterrain={GetPrimaryVoxelTerrainEntityID=function()return 1 end,
 GetWorldBounds=function()return vector(-1024,-2304,-1024),vector(1023,2303,1023)end}}
 end},entity={FindPrefab=function(name)return name:match('_Skirt$')~=nil end,
 CreateRequestCompletionToken=function()return 1 end,HaveRequestsCompleted=function()return true end,
 InstantiatePrefab=function(prefab,name,token,transform)
  assert(prefab=='NAT_Tree_Test_Skirt' and transform.position.x==600)
  instantiated=instantiated+1
  if fail and instantiated%2==0 then error('fixture spawn failure')end
  ids[instantiated]=true;return instantiated
 end,DestroyEntity=function(id)assert(ids[id] and not deleted[id]);deleted[id]=true end},
 undo=setmetatable({},{__index=function()error('Background/None touched undo')end})}
require=function(name)
 if name=='Vector3' then return V end
 if name=='Quaternion' then return {FromYawPitchRoll=function(v)return v end}end
 if name=='TransformQ' then return {FromOrPos=function(q,p)return {position=p,rotation=q}end}end
 error('Unexpected gameplay dependency '..name)
end
loadfile=function()return function()return {version=1,source=string.rep('a',64),groups={
 {resource='NAT_Tree_Test',instances={{600,20,0,0},{600,25,1,1}}}}}end end
local S=chunk()
-- Cluster registration is covered by test_scenery.lua; not needed for these fixtures.
S.AddPrefabs=function()end
local function world(mode)
 local w={parkExpansionsConfig={SceneryMode=mode},boundaryLabTerrainCreated=true,
 boundaryLabFilename='TaigaSandbox.bin'}
 S.BeforeLoad(w);return w
end
local function restore(w)
 local co=coroutine.create(function()S.AfterLoad(w,function()end)end)
 for i=1,100 do local ok,err=coroutine.resume(co);assert(ok,err)
  if coroutine.status(co)=='dead' then return end end
 error('did not finish')
end
local w=world('Background');restore(w)
assert(instantiated==2 and w.parkExpansionsScenery.backgroundCount==2 and w.parkExpansionsScenery.count==0)
local saved={};saves[#saves](saved)
assert(saved.complete==false and saved.count==0 and saved.mode=='Background')
S.Shutdown(w);S.Shutdown(w);assert(deleted[1] and deleted[2])
w=world('Background');loads(saved);restore(w)
assert(instantiated==4 and w.parkExpansionsScenery.backgroundCount==2,'Background was not recreated on reload')
S.Shutdown(w)
w=world('None');restore(w)
assert(instantiated==4 and w.parkExpansionsScenery.complete and w.parkExpansionsScenery.mode=='None')
saved={};saves[#saves](saved);assert(not saved.complete)
-- Legacy imports cannot be deleted or duplicated merely by editing config.
for _,record in ipairs({{complete=true,count=18880},{complete=false,count=128,nextIndex=129}})do
 w=world('None');loads(record);S.Queue(w)
 assert(w.parkExpansionsScenery.mode=='Editable' and w.parkExpansionsScenery.modeWarning)
 if record.complete then restore(w);assert(instantiated==4)end
end
-- A failed visual import cleans up its partial transient entities.
w=world('Background');fail=true;restore(w)
assert(w.parkExpansionsScenery.error:find('fixture spawn failure',1,true))
assert(deleted[5] and w.parkExpansionsBackgroundEntities==nil)
require=nativeRequire;loadfile=nativeLoadfile
print('PASS Background transient reload/cleanup; no undo or gameplay parts; None; legacy import preservation; failure cleanup')
