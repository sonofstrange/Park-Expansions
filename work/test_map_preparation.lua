local nativeLoadfile=loadfile
local function test(kind)
 local calls,yields=0,0
 local nativeRequest=false
 local progress={}
 api={save={GetSaveMetadata=function()return{tSave={sGameMode="sandbox",sGeome="taiga",parkExpansions=kind=="converted" and {} or kind=="saved4k" and {terrainSize=4096} or nil}}end}}
 local R=assert(nativeLoadfile('work/boundarylab/Main/boundarylab.research.lua'))()
 R.LoadingProgress=function(active,percent,message)progress[#progress+1]={active,percent,message}end
 package.loadlib=function(path,symbol)
  assert(symbol=="Begin")
  return function(identifier,name,biome,nonce)
   for _,value in ipairs({identifier,name,biome,nonce})do assert(type(value)=="string" and #value>0,"Native bridge rejects empty arguments")end
   nativeRequest=identifier=="__initialize_sea__"
   if nativeRequest then return end
   calls=calls+1;assert(identifier=="__prepare_map__" and name=="Terrain preparation" and biome==(kind=="converted" and "taiga" or "taiga:4096"))
  end
 end
 loadfile=function(path,mode,env)
  assert(mode=="t" and type(env)=="table")
  if path:find("BridgeInfo",1,true)then return function()return{version=32,supported=true}end end
  if path:find("State-",1,true)then return function()return nativeRequest and {status="sea_ready",seaRaster=4096} or {status="working"}end end
  if path:find("Progress-",1,true)then return function()return{status="working",progress=37,message="Reading terrain"}end end
  if path:find("Result-",1,true)then
   if yields==0 then return nil end
   return function()
    if kind=="failure"then return{status="error",message="Disk unavailable"}end
    return{status="map_ready",terrainSize=kind=="converted" and 2048 or 4096,filename=kind=="invalid" and "../other.bin" or "TaigaSandbox.bin"}
   end
  end
  return nil
 end
 assert(R.InitializeNative())
 local world={parkLoadSaveManager={tLoadParkFromFileRequest={sFileName="/run/Parks/Sandbox/TaigaSandbox.bin"}}}
 if kind=="unsupported"then world.parkLoadSaveManager.tLoadParkFromFileRequest.sFileName="/run/Parks/Scenarios/TaigaSandbox.bin"end
 if kind=="old" or kind=="converted" or kind=="saved4k" then world.parkLoadSaveManager={tLoadParkFromSaveTokenRequest={cSaveToken={}}}end
 local result
 local co=coroutine.create(function()result=R.PrepareMap(world)end)
 for i=1,10 do
  local ok,err=coroutine.resume(co);assert(ok,err)
  if coroutine.status(co)=="dead"then break end
  yields=yields+1
 end
 assert(coroutine.status(co)=="dead")
 if kind=="old"or kind=="unsupported"then assert(calls==0 and result==true)
 elseif kind=="failure"or kind=="invalid"then assert(result==false and world.parkExpansionsMapFailed)
 else
  assert(calls==1 and yields==1 and result==true)
  assert(progress[2][1]==true and progress[2][2]==37 and progress[2][3]=="Reading terrain","Worker progress was not sent to loading view")
  assert(R.PrepareMap(world)==true and calls==1,"Session cache launched another worker")
 end
 loadfile=nativeLoadfile
 print("PASS map preparation "..kind)
end
for _,kind in ipairs({"fresh","converted","saved4k","old","unsupported","failure","invalid"})do test(kind)end

local registered=false
api={world={GetWorldAPIs=function()return{worldserialisation={RegisterWorldSerialisationClient=function()registered=true end}}end}}
local R=assert(nativeLoadfile('work/boundarylab/Main/boundarylab.research.lua'))()
R.LoadConfig=function(world)world.parkExpansionsConfig={ResearchEnabled=true}end
R.PrepareMap=function(world)world.parkExpansionsAutoError="Terrain preparation request was not accepted.";return false end
R.AutoConvert=function()error("Failed preparation must not start conversion")end
local world={parkLoadSaveManager={tLoadParkFromFileRequest={sFileName="/run/Parks/Sandbox/TaigaSandbox.bin"}}}
local ok,message=pcall(R.BeforeLoad,world)
assert(ok,message);assert(registered and world.parkExpansionsMapFailed)
R.AfterLoad(world,{})
assert(world.boundaryLabResearch.managed==false and world.boundaryLabMessage:find("not accepted",1,true))
print('PASS real BeforeLoad and AfterLoad retain original load on preparation rejection without throwing')
