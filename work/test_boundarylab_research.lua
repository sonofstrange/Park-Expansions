-- Research state-machine tests. Native rendering and placement-box behavior still
-- require a game test; this covers sequencing, persistence and transactions.
local originalRequire=require
local function vec(x,y,z) return {x=x,y=y,z=z,GetX=function() return x end,GetY=function() return y end,GetZ=function() return z end} end
local V={new=function(_,x,y,z)return vec(x,y,z)end};V.XAxis=vec(1,0,0)
local balance,box,saveCallback,loadCallback,suspended,resumed,clipboard
local nextEntity=0
local alive={}
local creationFails=false
local serial={RegisterWorldSerialisationClient=function(_,name,version,save,load)
 assert(name=='BoundaryLabResearch' and version==1);saveCallback=save;loadCallback=load end,
 UnregisterWorldSerialisationClient=function()end}
local w={techtree={GetResearchPoints=function()return balance end,SetResearchPoints=function(_,value)balance=value end},
 park={SetEnforcedPlacementArea=function()error('Do not create mission guide graphics')end,
 ClearEnforcedPlacementArea=function()enforcedAreaCleared=true end,
 UnlockAllPlots=function()plotsUnlocked=true end,
 ClearAllPlotRestrictions=function()plotRestrictionsCleared=true end},
 crowdsimulation={SetVoxelTerrain=function()end},
 editors={CopyToClipboard=function(_,text)clipboard=text end},worldserialisation=serial,
 voxelterrain={GetPrimaryVoxelTerrainEntityID=function()return 1 end,
 GetWorldBounds=function()return vec(-1024,-2304,-1024),vec(1023,2303,1023)end}}
api={entity={
 CreateRequestCompletionToken=function()return {}end,
 HaveRequestsCompleted=function()return true end,
 InstantiatePrefab=function(name,label,token,transform,parent,params,props)
  if creationFails then error('Simulated ceiling creation failure')end
  assert(name=='ParkBoundaryBox' and label=='ParkExpansionsHeightCeiling')
  assert(props.Rotation.x==0 and props.Rotation.y==0 and props.Rotation.z==0)
  assert(props.HalfSize.x==2048 and props.HalfSize.z==2048)
  box={top=props.Position.y-props.HalfSize.y,upper=props.Position.y+props.HalfSize.y}
  nextEntity=nextEntity+1;alive[nextEntity]=box;return nextEntity
 end,
 DestroyEntity=function(id)assert(alive[id]);alive[id]=nil end},world={GetWorldAPIs=function()return w end},undo={IsBusy=function()return false end},
 save={CreateSaveSuspensionControl=function()return{
 SuspendSave=function()suspended=suspended+1 end,ResumeSave=function()resumed=resumed+1 end}end},
 player={GetGameOwner=function()return 7 end}}
require=function(name)
 if name=='Vector3' or name=='Vector2' then return V end
 if name=='Rotation' then return {FromAxisAngle=function(axis,angle)return{axis=axis,angle=angle}end} end
 if name=='Quaternion' then return {FromRotation=function(r)return r end}end
 if name=='TransformQ' then return {FromOrPos=function(rotation,pos)return{rotation=rotation,pos=pos}end}end
 return originalRequire(name)
end
local R=assert(loadfile('work/boundarylab/Main/boundarylab.research.lua'))()
assert(table.concat(R.Costs,',')=='12500,25000,50000,100000,200000')
local templates={['/run/parks/sandbox/taigasandbox.bin']={seed={0,0,0},bounds={-500,500,-500,500}}}
local function create(isFree)
 balance=1000000;suspended=0;resumed=0;box=nil
 local world={boundaryLabTerrainCreated=true,boundaryLabFilename='TaigaSandbox.bin',
 sandboxSettingsManager={GetCurrentSandboxSettings=function()return{bEnableResearchTree=not isFree}end}}
 R.BeforeLoad(world);assert(loadCallback({})==true);R.AfterLoad(world,templates)
 assert(world.boundaryLabResearch.width==0 and world.boundaryLabResearch.height==0)
 assert(box.top==255 and box.upper==8192)
 return world
end
local function run(world,fail)
 R.Advance(world,function(self,width)
  assert(self==world and width>1024 and width<=4096)
  if fail then R.Finish(self,false,'rejected');return end
  self.boundaryLabCommitResult={seed={width/2,42,0},bounds={-width/2,width/2,-width/2,width/2}}
 end)
 while world.boundaryLabTask and coroutine.status(world.boundaryLabTask)~='dead' do
  assert(coroutine.resume(world.boundaryLabTask))
 end
 world.boundaryLabTask=nil
end
local world=create(false)
R.Request('width',2);assert(not world.boundaryLabQueued and balance==1000000)
R.Request('invalid',1);R.Request('height',1.5);assert(balance==1000000)
print('PASS invalid and skipped research rejected')
R.Request('width',1);assert(balance==987500 and suspended==1)
R.Request('height',1);assert(balance==987500)
run(world);assert(world.boundaryLabResearch.width==1 and world.boundaryLabResearch.height==0 and resumed==1)
assert(world.boundaryLabActiveSeed[1]==576 and world.boundaryLabExpectedBounds[2]==576)
print('PASS independent width purchase and double-click protection')
R.Request('width',2);run(world,true)
assert(world.boundaryLabResearch.width==1 and balance==987500 and resumed==2)
print('PASS engine rejection returns points and releases saves')
for level=1,5 do R.Request('height',level);run(world);assert(box.top==R.Heights[level]) end
assert(box.top==2048 and world.boundaryLabResearch.height==5 and world.boundaryLabResearch.width==1)
print('PASS five height steps are independent and end at Y2048')

for level=2,5 do R.Request('width',level);run(world)end
assert(world.boundaryLabResearch.width==5 and world.boundaryLabExpectedBounds[2]==1020)
local spent=balance
R.Request('width',5);run(world);R.Request('height',6);assert(balance==spent and not world.boundaryLabQueued)
print('PASS five width steps end at 2040; reapply is free and does not duplicate history')
assert(#world.boundaryLabResearch.history==4)
local saved={};saveCallback(saved)
R.Shutdown(world)
local other={sandboxSettingsManager=world.sandboxSettingsManager}
R.BeforeLoad(other);loadCallback(saved);R.AfterLoad(other,templates);assert(plotsUnlocked and plotRestrictionsCleared and enforcedAreaCleared)
assert(other.boundaryLabResearch.width==5 and other.boundaryLabResearch.height==5 and box.top==2048)
assert(other.boundaryLabActiveSeed[1]==1020 and other.boundaryLabTerrainCreated)
R.Report();assert(clipboard:find('WIDTH_LEVEL=5 HEIGHT_LEVEL=5',1,true))
print('PASS save reload restores tiers and exact contour seed')
local world4k=create(false)
world4k.parkExpansionsTerrainSize=4096
balance=2000000
for level=1,5 do R.Request('width',level);run(world4k) end
assert(world4k.boundaryLabResearch.width==5 and world4k.boundaryLabExpectedBounds[2]==1020)
local balBefore6=balance
R.Request('width',6);run(world4k)
assert(world4k.boundaryLabResearch.width==6 and world4k.boundaryLabExpectedBounds[2]==1536)
assert(balBefore6-balance==400000)
local balBefore7=balance
R.Request('width',7);run(world4k)
assert(world4k.boundaryLabResearch.width==7 and world4k.boundaryLabExpectedBounds[2]==2044)
assert(balBefore7-balance==800000)
R.Request('width',8)
assert(not world4k.boundaryLabQueued)
local saved4k={};saveCallback(saved4k)
R.Shutdown(world4k)
local other4k={sandboxSettingsManager=world4k.sandboxSettingsManager,parkExpansionsTerrainSize=4096}
R.BeforeLoad(other4k);loadCallback(saved4k);R.AfterLoad(other4k,templates)
assert(other4k.boundaryLabResearch.width==7 and other4k.boundaryLabActiveSeed[1]==2044)
R.Shutdown(other4k)
print('PASS 4K width research expands to 7 steps with 400k/800k pricing and roundtrip saves')
world=create(false);balance=10
R.Request('width',1);assert(not world.boundaryLabQueued and suspended==0 and balance==10)
print('PASS insufficient points leaves the world untouched')
world=create(true);balance=0
R.Request('width',1);run(world);assert(balance==0 and world.boundaryLabResearch.width==1)
print('PASS sandbox research-disabled mode opens steps without a charge')
world.boundaryLabProgress=0
R.Progress(world,50,'test');R.Progress(world,25,'test');assert(world.boundaryLabProgress==50)
print('PASS progress never moves backwards within an operation')
R.Request('height',1);local reserved=balance;R.Shutdown(world);assert(balance==reserved)
local paid=create(false);R.Request('width',1);assert(balance==987500);R.Shutdown(paid);assert(balance==1000000 and resumed==1)
print('PASS shutdown before commit refunds reservation and releases saves')
local retry=create(false)
R.Request('height',1);run(retry)
local paidBalance=balance;local previous=retry.parkExpansionsHeightEntity
R.Request('height',1);run(retry)
assert(balance==paidBalance and not alive[previous] and alive[retry.parkExpansionsHeightEntity])
print('PASS saved height reapply is free and replaces the ceiling entity')
creationFails=true
R.Request('height',2)
R.Advance(retry,function()error('Unexpected width operation')end)
local success,message
while coroutine.status(retry.boundaryLabTask)~='dead' do
 success,message=coroutine.resume(retry.boundaryLabTask)
 if not success then break end
end
assert(not success and message:find('Simulated ceiling creation failure'))
R.Finish(retry,false,message)
assert(balance==paidBalance and retry.boundaryLabResearch.height==1 and alive[retry.parkExpansionsHeightEntity])
creationFails=false
print('PASS failed height volume creation preserves previous ceiling and refunds points')

-- Read the real configuration code with an isolated user-file fixture.
local originalLoadfile=loadfile
local configText
loadfile=function(path,mode,env)
 if path:match('Mod_BoundaryLab/Config.ini$') then return load(configText,'@Config.ini',mode,env)end
 return originalLoadfile(path,mode,env)
end
local function loadConfigured(text,saved)
 configText=text;balance=12345;suspended=0;resumed=0;box=nil
 local world={boundaryLabTerrainCreated=true,boundaryLabFilename='TaigaSandbox.bin',
 sandboxSettingsManager={GetCurrentSandboxSettings=function()return{bEnableResearchTree=true}end}}
 R.BeforeLoad(world);assert(loadCallback(saved or {})==true);R.AfterLoad(world,templates)
 return world
end
local function driveManual(world,expectedSize,expectedHeight,expectedCalls)
 local calls=0
 R.Advance(world,function(self,size,allowShrink)
  calls=calls+1;assert(self==world and size==expectedSize and allowShrink==true)
  self.boundaryLabCommitResult={seed={-size/2,42,0},bounds={-size/2,size/2,-size/2,size/2}}
 end)
 while world.boundaryLabTask and coroutine.status(world.boundaryLabTask)~='dead' do
  local ok,message=coroutine.resume(world.boundaryLabTask);assert(ok,message)
 end
 world.boundaryLabTask=nil
 assert(calls==expectedCalls and box.top==expectedHeight)
 assert(balance==12345 and resumed==1 and not world.boundaryLabResearchBusy)
end
local manual=loadConfigured('ResearchEnabled=false;ManualParkSize=1800;ManualMaxHeight=1600')
assert(manual.boundaryLabQueued and suspended==1 and not box)
R.Request('width',1);R.Request('height',1);assert(balance==12345)
driveManual(manual,1800,1600,1)
assert(manual.boundaryLabResearch.width==0 and manual.boundaryLabResearch.height==0)
local manualSave={};saveCallback(manualSave);R.Shutdown(manual)
print('PASS manual limits auto-apply without points or research unlock changes')
local same=loadConfigured('ResearchEnabled=false;ManualParkSize=1800;ManualMaxHeight=1700',manualSave)
driveManual(same,1800,1700,0)
assert(#same.boundaryLabResearch.history==0)
R.Shutdown(same)
print('PASS manual reload applies height without rebuilding the unchanged boundary')
local smaller=loadConfigured('ResearchEnabled=false;ManualParkSize=512;ManualMaxHeight=5000',manualSave)
driveManual(smaller,512,5000,1)
assert(smaller.parkExpansionsConfig.warning and box.upper>5000)
R.Shutdown(smaller)
print('PASS explicit manual shrinking and uncapped height above 2048 with warning')
manualSave.width=3;manualSave.height=2
local research=loadConfigured('ResearchEnabled=true',manualSave)
assert(not research.boundaryLabQueued and box.top==700)
assert(research.boundaryLabResearch.width==3 and research.boundaryLabResearch.height==2)
R.Shutdown(research)
print('PASS enabling research restores purchased height and preserves saved unlocks')
local large=loadConfigured('ResearchEnabled=false;ManualParkSize=3000;ManualMaxHeight=10000')
assert(large.parkExpansionsConfig.ManualParkSize==3000 and large.parkExpansionsConfig.ManualMaxHeight==10000)
assert(large.parkExpansionsConfig.warning and large.boundaryLabQueued)
R.Shutdown(large)
print('PASS above-2048 requests accepted without configuration clamping')
for _,text in ipairs({'ResearchEnabled="no"','ResearchEnabled=false;ManualParkSize=0',
 'ResearchEnabled=false;ManualMaxHeight=0/0','ResearchEnabled=false;ManualParkSize=1/0','ResearchEnabled=',
 'Enable4KMap="no"','MaxMapSize=8192'})do
 local invalid=loadConfigured(text)
 assert(invalid.parkExpansionsConfig.error and invalid.parkExpansionsConfig.ResearchEnabled==true and invalid.parkExpansionsConfig.Enable4KMap==false)
 assert(not invalid.boundaryLabQueued and balance==12345)
 R.Shutdown(invalid)
end
print('PASS malformed config, invalid types and nonfinite numbers fail without applying manual limits')
local defaultCfg=loadConfigured('ResearchEnabled=true')
assert(defaultCfg.parkExpansionsConfig.Enable4KMap==false and defaultCfg.parkExpansionsConfig.MaxMapSize==2048)
R.Shutdown(defaultCfg)
local enable4k=loadConfigured('Enable4KMap=true')
assert(enable4k.parkExpansionsConfig.Enable4KMap==true and enable4k.parkExpansionsConfig.MaxMapSize==4096)
R.Shutdown(enable4k)
local maxMap4k=loadConfigured('MaxMapSize=4096')
assert(maxMap4k.parkExpansionsConfig.Enable4KMap==true and maxMap4k.parkExpansionsConfig.MaxMapSize==4096)
R.Shutdown(maxMap4k)
print('PASS map size configuration defaults to 2048 and accepts 4096 via Enable4KMap or MaxMapSize')
loadfile=originalLoadfile

-- Existing unmodified saves must explain the block without spending points.
local oldPark={sandboxSettingsManager={GetCurrentSandboxSettings=function()return{bEnableResearchTree=true}end}}
balance=500000
R.BeforeLoad(oldPark);loadCallback({});R.AfterLoad(oldPark,templates)
assert(not oldPark.boundaryLabResearch.managed and oldPark.boundaryLabMessage:find('not registered'))
R.Request('width',1);assert(balance==500000 and not oldPark.boundaryLabPurchase)
R.Report();assert(clipboard:find('UNSUPPORTED_REASON=This park is not registered',1,true))
R.Shutdown(oldPark)
local boundsFunction=w.voxelterrain.GetWorldBounds
w.voxelterrain.GetWorldBounds=function()return vec(-512,-256,-512),vec(511,255,511)end
local incompatible={}
R.BeforeLoad(incompatible)
loadCallback({managed=true,width=1,height=1,filename='TaigaSandbox.bin'})
R.AfterLoad(incompatible,templates)
assert(not incompatible.boundaryLabResearch.managed and incompatible.boundaryLabMessage:find('incompatible terrain'))
R.Request('height',2);assert(balance==500000 and not incompatible.boundaryLabPurchase)
R.Shutdown(incompatible)
w.voxelterrain.GetWorldBounds=boundsFunction
print('PASS old and incompatible saves show an explicit reason and cannot spend research points')

-- Conversion metadata must be read before native loading, then validated against
-- the actual extended volume. Unconverted saves remain blocked.
local metadata={tSave={parkExpansions={version=1,filename='TaigaSandbox.bin',
 seed={-486,76,-486},bounds={-503,511,-511,414},sourceHash='test'}}}
api.save.GetSaveMetadata=function(token)assert(token=='converted-save');return metadata end
local adopted={parkLoadSaveManager={tLoadParkFromSaveTokenRequest={cSaveToken='converted-save',sTerrainFileName='original.trn'}}}
balance=500000;suspended=0;resumed=0
R.BeforeLoad(adopted)
assert(adopted.parkLoadSaveManager.tLoadParkFromSaveTokenRequest.sTerrainFileName=='/run/Win64/ovldata/Mod_BoundaryLab/Maps/TaigaSandbox.trn')
loadCallback({});R.AfterLoad(adopted,templates)
assert(adopted.boundaryLabResearch.managed and adopted.boundaryLabResearch.width==0 and adopted.boundaryLabResearch.height==0)
assert(adopted.boundaryLabActiveSeed[1]==-486 and adopted.boundaryLabExpectedBounds[2]==511)
assert(adopted.boundaryLabTerrainCreated and adopted.boundaryLabTemplate)
R.Request('width',1);assert(balance==487500);run(adopted)
assert(adopted.boundaryLabResearch.width==1)
local metadataHook
local priorRequire=require
require=function(name)
 if name=='forgeutils.hookmanager' then return {AddHook=function(_,module,method,fn)
  assert(module=='Managers.ParkLoadSaveManager' and method=='GenerateCurrentParkMetaData');metadataHook=fn end}end
 return priorRequire(name)
end
R.InstallCompatibilityHooks();require=priorRequire
local nextMetadata=metadataHook(function()return{tSave={sGameMode='challenge',sParkName='Existing name'}}end,{})
assert(nextMetadata.tSave.sGameMode=='challenge' and nextMetadata.tSave.sParkName=='Existing name')
assert(nextMetadata.tSave.parkExpansions.seed[1]==576 and nextMetadata.tSave.parkExpansions.bounds[2]==576)
local adoptedSave={};saveCallback(adoptedSave);R.Shutdown(adopted)
metadata=nextMetadata
local ordinaryReload={parkLoadSaveManager={tLoadParkFromSaveTokenRequest={cSaveToken='converted-save'}}}
R.BeforeLoad(ordinaryReload);loadCallback(adoptedSave);R.AfterLoad(ordinaryReload,templates)
assert(ordinaryReload.parkLoadSaveManager.tLoadParkFromSaveTokenRequest.sTerrainFileName:find('TaigaSandbox.trn',1,true))
assert(ordinaryReload.boundaryLabResearch.managed and ordinaryReload.boundaryLabResearch.width==1)
R.Shutdown(ordinaryReload)
print('PASS converted old save adopts actual contour, can research and persists as a normal managed park')
local oldBounds=w.voxelterrain.GetWorldBounds
w.voxelterrain.GetWorldBounds=function()return vec(-512,-256,-512),vec(511,255,511)end
local unextended={parkLoadSaveManager={tLoadParkFromSaveTokenRequest={cSaveToken='converted-save'}}}
R.BeforeLoad(unextended);loadCallback({});R.AfterLoad(unextended,templates)
assert(not unextended.boundaryLabResearch.managed and unextended.boundaryLabMessage:find('did not validate'))
R.Shutdown(unextended);w.voxelterrain.GetWorldBounds=oldBounds
metadata.tSave.parkExpansions.filename='../wrong.bin'
local invalidConverted={parkLoadSaveManager={tLoadParkFromSaveTokenRequest={cSaveToken='converted-save',sTerrainFileName='original.trn'}}}
R.BeforeLoad(invalidConverted);loadCallback({});R.AfterLoad(invalidConverted,templates)
assert(not invalidConverted.parkExpansionsConverted and invalidConverted.parkLoadSaveManager.tLoadParkFromSaveTokenRequest.sTerrainFileName=='original.trn')
R.Shutdown(invalidConverted)
api.save.GetSaveMetadata=nil
print('PASS conversion marker cannot bypass actual volume validation or request arbitrary underlays')
local convertedMessage=create(false)
convertedMessage.parkExpansionsAutoStatus='Park conversion successful.'
convertedMessage.parkExpansionsConfig={ResearchEnabled=true}
R.AfterLoad(convertedMessage,templates)
assert(convertedMessage.boundaryLabMessage=='Park conversion successful.')
creationFails=true
R.AfterLoad(convertedMessage,templates)
assert(convertedMessage.boundaryLabMessage:find('Height setup failed',1,true))
creationFails=false
R.Shutdown(convertedMessage)
print('PASS concise conversion success text; height failures remain visible instead of being hidden by success')

-- Test auto-backup of normal parks
local backupCalled = 0
local lastBackupId, lastBackupName
package = {loadlib=function(dll, fn)
    assert(dll:find("ParkExpansionsBridge.dll") and fn=="Begin")
    return function(cmd, saveId, parkName, nonce)
        if cmd == "__backup_save__" then
            backupCalled = backupCalled + 1
            lastBackupId = saveId
            lastBackupName = parkName
        end
    end
end}
api.save.GetSaveMetadata = function(token)
    if token == "vanilla-token" then return {sName="VanillaPark", tSave={sParkName="VanillaPark"}} end
    if token == "modded-token" then return {sName="ModdedPark", tSave={parkExpansions={version=1}}} end
    return nil
end
api.save.GetSaveIdentifier = function(token) return token == "vanilla-token" and "1234ABCD" or "5678EF01" end

local vanillaPark = {parkLoadSaveManager={tLoadParkFromSaveTokenRequest={cSaveToken="vanilla-token"}}}
R.BackupNormalPark(vanillaPark)
assert(backupCalled == 1 and lastBackupId == "1234ABCD" and lastBackupName == "VanillaPark", "Vanilla park must be backed up")

local moddedPark = {parkLoadSaveManager={tLoadParkFromSaveTokenRequest={cSaveToken="modded-token"}}}
R.BackupNormalPark(moddedPark)
assert(backupCalled == 1, "Already managed park must not trigger normal park backup")

local newPark = {parkLoadSaveManager={}}
R.BackupNormalPark(newPark)
assert(backupCalled == 1, "New park from template must not trigger save backup")
print('PASS auto-backup triggers for normal unmanaged parks and skips modded/new maps')

package = nil
api.save.GetSaveMetadata = nil
api.save.GetSaveIdentifier = nil
require=originalRequire
