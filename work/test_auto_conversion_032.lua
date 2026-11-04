local realLoadfile=loadfile
local realRequire=require
local realLoadlib=package.loadlib
local oldApi=api
local request,states,metadata,beginCalls,yields,loadingProgress,expectedSize
api={save={GetSaveMetadata=function(token) assert(token=='old-token');return metadata end,
 GetSaveIdentifier=function(token)assert(token=='old-token');return 389262725 end,
 IsSaveToken=function()return true end}}
local R=assert(realLoadfile('work/boundarylab/Main/boundarylab.research.lua'))()
local info={version=1,filename='TropicalSandbox.bin',seed={1,2,3},bounds={-500,500,-500,500}}
local native='/run/Win64/ovldata/Mod_BoundaryLab/AutoConversion/'..string.rep('a',64)..'.bin'
local function reset()
 expectedSize=2048;info.terrainSize=nil
 metadata={sName='Old Park',tSave={sGameMode='challenge',sGeome='tropical'}}
 beginCalls=0;yields=0;loadingProgress={}
 R.LoadingProgress=function(active,percent,message)loadingProgress[#loadingProgress+1]={active,percent,message}end
 states={{status='working',progress=20},{status='ready',native=native,info=info,requestIdentifier='389262725',sourceIdentifier='389262725'}}
 package.loadlib=function(path,symbol)
  assert(path:find('ParkExpansionsBridge.dll',1,true) and symbol=='Begin')
  return function(id,name,biome,nonce)
   assert(id=='389262725' and name=='Old Park' and biome=='tropical:'..expectedSize)
   assert(nonce:match('^%d+%-%d+$'));beginCalls=beginCalls+1
  end
 end
 loadfile=function(path,mode,env)
  assert(mode=='t' and type(env)=='table')
  if path:find('BridgeInfo.lua',1,true)then return function()return{version=32,supported=true,saveIdentityVersion=1}end end
  if path:find('State-',1,true)then return function()return{status='working',progress=0}end end
  if path:find('Result-',1,true)then
   if #states==1 or yields>0 then return function()return states[#states]end end
   return nil
  end
  if path:find('Progress-',1,true)then return function()return states[1]end end
  return realLoadfile(path,mode,env)
 end
 return {parkLoadSaveManager={tLoadParkFromSaveTokenRequest={cSaveToken='old-token',sTerrainFileName='original.trn'},
   cLastActiveParkSaveToken='old-token'}}
end
local function run(world)
 local co=coroutine.create(function()R.AutoConvert(world)end)
 for frame=1,10 do
  local ok,message=coroutine.resume(co);assert(ok,message)
  if coroutine.status(co)=='dead'then return end
  yields=yields+1
 end
 error('conversion did not finish')
end
local world=reset();run(world)
local manager=world.parkLoadSaveManager
assert(beginCalls==1 and yields==1)
assert(loadingProgress[2][1] and loadingProgress[2][2]==20,"Conversion progress did not reach loading view")
assert(manager.tLoadParkFromSaveTokenRequest==nil and manager.cLastActiveParkSaveToken==nil)
assert(manager.tLoadParkFromFileRequest.sFileName==native)
R.ReadConvertedSave(world)
assert(world.parkExpansionsConverted==info and world.parkExpansionsAutoStatus=='Park conversion successful.')
assert(manager.tLoadParkFromFileRequest.sTerrainFileName=='/run/Win64/ovldata/Mod_BoundaryLab/Maps/TropicalSandbox.trn')
print('PASS automatic conversion waits before native loading, uses matching terrain, and clears original overwrite token')
world=reset();expectedSize=4096;info.terrainSize=4096
world.parkExpansionsConfig={MaxMapSize=4096}
run(world);R.ReadConvertedSave(world)
assert(world.parkExpansionsTerrainSize==4096)
assert(world.parkLoadSaveManager.tLoadParkFromFileRequest.sTerrainFileName:find('/Maps4096/',1,true))
world=reset();expectedSize=4096;world.parkExpansionsConfig={MaxMapSize=4096}
run(world)
assert(world.parkExpansionsAutoError:find('terrain size',1,true))
assert(world.parkLoadSaveManager.tLoadParkFromSaveTokenRequest.cSaveToken=='old-token')
print('PASS 4K request and underlay routing; wrong-size conversion preserves original selected save')
world=reset();states={{status='error',message='Preservation check failed'}};run(world)
assert(world.parkExpansionsAutoError=='Preservation check failed')
assert(world.parkLoadSaveManager.cLastActiveParkSaveToken=='old-token')
assert(world.parkLoadSaveManager.tLoadParkFromSaveTokenRequest.cSaveToken=='old-token')
world=reset();states={{status='ready',native='../invalid.bin',info=info}};run(world)
assert(world.parkExpansionsAutoError and world.parkLoadSaveManager.cLastActiveParkSaveToken=='old-token')
world=reset();states={{status='skip'}};run(world)
assert(not world.parkExpansionsAutoError and world.parkLoadSaveManager.cLastActiveParkSaveToken=='old-token')
world=reset();states={{status='ready',native=native,info=info,requestIdentifier='389262725',sourceIdentifier='123'}};run(world)
assert(world.parkExpansionsAutoError:find('identity',1,true))
assert(world.parkLoadSaveManager.tLoadParkFromSaveTokenRequest.cSaveToken=='old-token')
world=reset();states={{status='ready',native=native,info=info,requestIdentifier='123',sourceIdentifier='389262725'}};run(world)
assert(world.parkExpansionsAutoError:find('identity',1,true))
world=reset();states={{status='ready',native=native,info=info}};run(world)
assert(world.parkExpansionsAutoError:find('identity',1,true))
world=reset()
local co=coroutine.create(function()R.AutoConvert(world)end)
assert(coroutine.resume(co))
world.parkLoadSaveManager.tLoadParkFromSaveTokenRequest={cSaveToken='different-token'}
yields=1;assert(coroutine.resume(co));assert(coroutine.status(co)=='dead')
assert(world.parkExpansionsAutoError:find('selected save changed',1,true))
assert(world.parkLoadSaveManager.tLoadParkFromSaveTokenRequest.cSaveToken=='different-token')
world=reset()
local bridgeLoadfile=loadfile
loadfile=function(path,...)
 if path:find('BridgeInfo.lua',1,true) then return function()return {version=32,supported=true}end end
 return bridgeLoadfile(path,...)
end
run(world)
assert(world.parkExpansionsAutoError:find('Update the Park Expansions bridge',1,true))
assert(world.parkLoadSaveManager.tLoadParkFromSaveTokenRequest.cSaveToken=='old-token')
print('PASS wrong/missing response identity and changed selection never replace the selected park')
print('PASS failed/invalid conversions preserve original request and token; managed worlds skip conversion')
world=reset();package.loadlib=nil;run(world)
assert(world.parkExpansionsAutoError:find('unavailable') and beginCalls==0)
world=reset();metadata.tSave.sGameMode='franchise';run(world);assert(beginCalls==0)
world=reset();metadata.tSave.parkExpansions=info;run(world);assert(beginCalls==0)
world=reset();metadata.tSave.sGeome='unknown';run(world);assert(beginCalls==0)
print('PASS missing native component, online parks, unsupported biomes and converted saves are handled without conversion')
loadfile=realLoadfile;require=realRequire;package.loadlib=realLoadlib;api=oldApi

-- The bundled Lua test host is Win32, whereas the game and module are Win64.
-- The actual Win64 DLL/build guard is exercised by the Python test below.
