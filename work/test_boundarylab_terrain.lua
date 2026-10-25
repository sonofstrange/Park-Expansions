-- Lifecycle checks for copied terrain loading. No regeneration is permitted.
local source="work/boundarylab/Main/database.mod_boundarylabluadatabase.lua"
local originalIO,originalRequire,originalLoadfile=io,require,loadfile
local function test(label,options)
 options=options or {}
 local function vec(x,y,z) return {GetX=function() return x end,GetY=function() return y end,GetZ=function() return z end} end
 local V={new=function(_,x,y,z) return vec(x,y,z) end}
 local filename=options.unsupported and "sandbox_c0_tiny.bin" or options.biome or "TemperateSandbox.bin"
 local input="/run/Parks/Sandbox/"..filename
 local request={sFileName=input,sTerrainFileName=input:gsub("%.bin$",".trn")}
 local manager={tLoadParkFromFileRequest=request}
 if options.saved then manager.tLoadParkFromFileRequest=nil;manager.tLoadParkFromSaveTokenRequest={} end
 local eligible=not options.unsupported and not options.saved and not options.mapFail
 local report,noticeCount,loaded= nil,0,0
 local w={editors={CopyToClipboard=function(_,text) report=text end},voxelterrain={
  GetPrimaryVoxelTerrainEntityID=function() return 11 end,
  GetWorldBounds=function()
   if options.shortHeight then return vec(-1024,-256,-1024),vec(1023,255,1023) end
   return vec(-1024,-2304,-1024),vec(1023,2303,1023)
  end,
  RayCast=function(_,id,start,direction,depth)
   assert(id==11 and start:GetY()==2304 and depth==4609,"Incorrect native ground probe")
   if options.badGround then return nil end
   if options.slopedGround and start:GetX()==600 then return 2224 end
   return 2288.5
  end}}
 api={world={GetWorldAPIs=function() return w end},debug={Trace=function() end},entity={
  DestroyEntity=function() error("Original terrain must never be destroyed") end,
  InstantiatePrefab=function() error("Generator must not be invoked") end}}
 io=nil
 loadfile=function(path,...)
  local env=select(2,...)
  if path:find("GroundChecks.lua",1,true) then
   if options.missingChecks then return nil,"missing checks" end
   return function() env.Heights={[filename]={[600]=options.slopedGround and 80 or 15.5,[750]=15.5,[900]=15.5}} end
  end
  return originalLoadfile(path,...)
 end
 require=function(name)
  if name=="boundarylab.research" then
   return {Progress=function() end,Finish=function() end,AddUIHooks=function() end,Advance=function() end,
    BeforeLoad=function(world)world.parkExpansionsMapFailed=options.mapFail end,AfterLoad=function() end}
  end
  if name=="Vector3" then return V end
  if name=="Helpers.PopUpDialogUtils" then return {RunOKDialog=function() noticeCount=noticeCount+1 end} end
  return originalRequire(name)
 end
 local self={parkLoadSaveManager=manager,_MakeTerrain=function() error("Original terrain factory called") end}
 local class={OnAdvance=function() end,OnLoad=function()
  loaded=loaded+1
  if eligible then
   assert(request.sFileName=="/run/Win64/ovldata/Mod_BoundaryLab/Maps/"..filename,"Not loading the copied map")
   assert(request.sTerrainFileName==request.sFileName:gsub("%.bin$",".trn"),"Mismatched underlay path")
  else assert(request.sFileName==input,"Changed an ineligible load") end
  if options.failure then error("simulated file load failure") end
  return "loaded"
 end}
 local database=assert(loadfile(source))()
 database.AddLuaHooks(function(_,hook) hook(class) end)
 local ok,result=pcall(class.OnLoad,self,{GetWorldName=function() return "World" end})
 assert(loaded==1,"World loaded more than once")
 if options.failure then
  assert(not ok and not self.boundaryLabTerrainCreated,"Load error was ignored")
  assert(request.sFileName==input,"Original load request was not restored on failure")
  assert(report and report:find("PRESERVED_LOAD_ERROR",1,true),"Missing error report")
 elseif not eligible then
  assert(ok and result=="loaded" and not self.boundaryLabTerrainCreated and noticeCount==0)
 elseif options.shortHeight or options.badGround or options.missingChecks then
  assert(ok and not self.boundaryLabTerrainCreated and noticeCount==1,"Invalid terrain was allowed to expand")
 else
  assert(ok and result=="loaded" and self.boundaryLabTerrainCreated)
  assert(self.boundaryLabTemplate and #self.boundaryLabTemplate.bounds==4)
  assert(table.concat(self.boundaryLabLoadLines,"\n"):find("PRESERVED_TERRAIN",1,true))
 end
 io,require,loadfile=originalIO,originalRequire,originalLoadfile
 print("PASS "..label)
end
for _,biome in ipairs({"TemperateSandbox.bin","TropicalSandbox.bin","TaigaSandbox.bin","MediterraneanSandbox.bin"}) do
 test("copied "..biome.." loads without destroying terrain",{biome=biome})
end
test("saved parks bypass prepared maps",{saved=true})
test("scenario presets bypass prepared maps",{unsupported=true})
test("file failure restores original request",{failure=true})
test("unexpected height prevents contour expansion",{shortHeight=true})
test("missing outer ground prevents contour expansion",{badGround=true})
test("non-flat transition at x600 is accepted",{slopedGround=true})
test("missing stock validation file prevents boundary edit",{missingChecks=true})

test("preparation failure loads original park without partially initialized teardown",{mapFail=true})
