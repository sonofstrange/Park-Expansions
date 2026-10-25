-- Per-park research and HUD bridge. Geometry changes are delegated to the
-- already tested boundary operation; no game files or saves are edited here.
local g = _G
local api = g.api
local R = {Widths={1152,1344,1536,1792,2040}, Heights={400,700,1000,1500,2048}, Costs={12500,25000,50000,100000,200000}}
local wrappers = g.setmetatable({}, {__mode="k"})
local current
local loadingWrappers=g.setmetatable({}, {__mode="k"})
local loadingState={active=false,percent=0,message=""}
local loadingDiagnostics={routed=0,views=0,ready=0,updates=0,lastPercent=-1}

local function contours(world,template)
    local s=world.boundaryLabResearch
    local list={}
    if s.seed then list[#list+1]={seed=s.seed,bounds=s.bounds} end
    for _,value in g.ipairs(s.history or {}) do list[#list+1]=value end
    if template then list[#list+1]={seed=template.seed,bounds=template.bounds} end
    world.boundaryLabContourCandidates=list
end

local function state(world)
    world.boundaryLabResearch = world.boundaryLabResearch or {width=0,height=0,managed=false}
    return world.boundaryLabResearch
end

function R.LoadConfig(world)
    local values={}
    local chunk,message=g.loadfile("Win64/ovldata/Mod_BoundaryLab/Config.ini","t",values)
    local ok=chunk~=nil
    if ok then ok,message=g.pcall(chunk) end
    if ok then
        ok,message=g.pcall(function()
            if values.ResearchEnabled==nil then values.ResearchEnabled=true end
            g.assert(g.type(values.ResearchEnabled)=="boolean","ResearchEnabled must be true or false")
            if values.ManualParkSize==nil then values.ManualParkSize=2040 end
            if values.ManualMaxHeight==nil then values.ManualMaxHeight=2048 end
            local function finite(value)
                return g.type(value)=="number" and value==value and value~=g.math.huge and value~=-g.math.huge
            end
            g.assert(finite(values.ManualParkSize) and values.ManualParkSize>0,
                "ManualParkSize must be a finite positive number")
            g.assert(finite(values.ManualMaxHeight),"ManualMaxHeight must be a finite world Y coordinate")
            if values.ResearchEnabled==false and (values.ManualParkSize>2048 or values.ManualMaxHeight>2048) then
                values.warning="Values above 2048 may be unstable. Terrain and engine limits can still prevent placement."
            end
        end)
    end
    if not ok then values={ResearchEnabled=true,error="Config error: "..g.tostring(message)} end
    world.parkExpansionsConfig=values
    return values
end

local function settings(world)
    return world and world.parkExpansionsConfig or {ResearchEnabled=true}
end

local function points()
    return api.world.GetWorldAPIs().techtree:GetResearchPoints()
end

local function free(world)
    local manager = world.sandboxSettingsManager
    local settings = manager and manager:GetCurrentSandboxSettings()
    return settings and settings.bEnableResearchTree == false or false
end

local function jsonString(value)
    return '"'..g.tostring(value):gsub('[%z\1-\31\\"]',function(char)
        return g.string.format('\\u%04x',g.string.byte(char))
    end)..'"'
end

local loadingDirty=true
local loadingImports=g.setmetatable({}, {__mode="k"})
-- Called from the park-loading coroutine: update Lua data only. Native UI
-- requests must be made by the loading world's own Advance callback.
function R.LoadingProgress(active,percent,message)
    percent=g.tonumber(percent) or 0
    percent=g.math.max(0,g.math.min(100,g.math.floor(percent)))
    message=g.tostring(message or "")
    if loadingState.active==active and loadingState.percent==percent and loadingState.message==message then return end
    loadingState={active=active==true,percent=percent,message=message}
    loadingDirty=true
end
local function attachLoading(wrapper)
    if loadingWrappers[wrapper] then return end
    loadingWrappers[wrapper]=true
    loadingDiagnostics.views=loadingDiagnostics.views+1
    wrapper:AddEventListener("ParkExpansions_LoadingReady",0,function()
        loadingDiagnostics.ready=loadingDiagnostics.ready+1
        loadingDirty=true
    end,nil)
    wrapper:AddEventListener("ParkExpansions_LoadingAck",1,function(percent)
        if g.type(percent)=="number" then
            loadingDiagnostics.updates=loadingDiagnostics.updates+1
            loadingDiagnostics.lastPercent=percent
        end
    end,nil)
    wrapper:AddEventListener("ParkExpansions_RequestLoadProgress",0,function()loadingDirty=true end,nil)
    loadingDirty=true
end
function R.AdvanceLoading(world)
    loadingDiagnostics.worldTicks=(loadingDiagnostics.worldTicks or 0)+1
    local wrapper=world.loadingScreenUI
    if not wrapper or not wrapper:IsReady() then return end
    attachLoading(wrapper)
    if not loadingImports[wrapper] then
        wrapper:TriggerEventAtNextAdvance("ForgeUtils_AddImportHook","/js/boundarylab/loading.js")
        loadingImports[wrapper]=true
        loadingDiagnostics.routed=loadingDiagnostics.routed+1
        loadingDirty=true
    end
    if loadingDirty then
        local payload="["..g.tostring(loadingState.active)..","..g.tostring(loadingState.percent)..","..jsonString(loadingState.message).."]"
        wrapper:TriggerEventAtNextAdvance("ParkExpansions_LoadProgress",payload)
        loadingDirty=false
    end
end

function R.AdvanceGlobalLoading()
    loadingDiagnostics.ticks=(loadingDiagnostics.ticks or 0)+1
    if not loadingDirty and not loadingState.active then return end
    if not api.world.IsLoaded("loadingscreen") then return end
    local world=api.world.GetScript("loadingscreen")
    if world then R.AdvanceLoading(world) end
end

function R.Push()
    local world = current
    local s = world and state(world) or {width=0,height=0,managed=false}
    local balance = 0
    if world then local ok,value=g.pcall(points);if ok and g.type(value)=="number" then balance=value end end
    -- The native event binding has only FIVE argument slots. Passing eight
    -- overruns its stack before it checks the count; pcall cannot catch that.
    -- One JSON string carries the complete snapshot without native varargs.
    local payload="["..g.table.concat({g.tostring(s.managed),g.tostring(s.width),g.tostring(s.height),
        g.tostring(balance),g.tostring(world and world.boundaryLabResearchBusy or false),
        g.tostring(world and world.boundaryLabProgress or 0),
        jsonString(world and world.boundaryLabMessage or "Create a new empty sandbox to use park expansion."),
        g.tostring(world and free(world) or false),
        g.tostring(settings(world).ResearchEnabled),
        g.tostring(settings(world).ManualParkSize or 2040),
        g.tostring(settings(world).ManualMaxHeight or 2048)},",").."]"
    for wrapper in g.pairs(wrappers) do
        if wrapper:IsReady() then
            g.pcall(function() wrapper:TriggerEventAtNextAdvance("BoundaryLab_State",payload) end)
        end
    end
end

function R.Progress(world,percent,message)
    world.boundaryLabProgress=g.math.max(world.boundaryLabProgress or 0,percent)
    world.boundaryLabMessage=message
    R.Push()
end

-- ParkBoundaryBox has only SpatialBox, SpatialDatabase and Transform components.
-- Its enforcedPlacementArea group blocks intersections (native mask 0x8000000000000).
-- Put the box ABOVE the unlocked ceiling; do not rotate a mission area, whose
-- setter also creates six world-space GUI guide faces with a fixed 1000 m depth.
function R.ApplyHeight(world,level,configuredMaximum)
    local Vector3=g.require("Vector3")
    local maximum=configuredMaximum or (level==0 and 255 or R.Heights[level])
    local ceiling=g.math.max(8192,maximum+4096)
    local token=api.entity.CreateRequestCompletionToken()
    local id=api.entity.InstantiatePrefab("ParkBoundaryBox","ParkExpansionsHeightCeiling",token,nil,nil,nil,{
        HalfSize=Vector3:new(2048,(ceiling-maximum)/2,2048),
        Position=Vector3:new(0,(ceiling+maximum)/2,0),Rotation=Vector3:new(0,0,0)})
    g.assert(id,"Could not create the height ceiling volume")
    local ready=false
    for frame=1,600 do
        if api.entity.HaveRequestsCompleted(token) then ready=true;break end
        g.coroutine.yield()
    end
    if not ready then
        api.entity.DestroyEntity(id)
        g.error("Height ceiling creation timed out")
    end
    -- Replace only after the new volume is ready. Preserve the previous limit
    -- and the reserved points if creation fails before this point.
    api.world.GetWorldAPIs().park:ClearEnforcedPlacementArea()
    if world.parkExpansionsHeightEntity then api.entity.DestroyEntity(world.parkExpansionsHeightEntity) end
    world.parkExpansionsHeightEntity=id
    world.boundaryLabHeightApplied=level
    world.parkExpansionsHeightTop=maximum
    world.parkExpansionsHeightError=nil
end

local function validConvertedInfo(info)
    local allowed={['TemperateSandbox.bin']=true,['TropicalSandbox.bin']=true,
        ['TaigaSandbox.bin']=true,['MediterraneanSandbox.bin']=true}
    if g.type(info)~="table" or info.version~=1 or not allowed[info.filename]
        or g.type(info.seed)~="table" or g.type(info.bounds)~="table" then return false end
    for index=1,4 do
        local value=info.bounds[index]
        if g.type(value)~="number" or value~=value or g.math.abs(value)>1024 then return false end
    end
    for index=1,3 do
        local value=info.seed[index]
        if g.type(value)~="number" or value~=value or g.math.abs(value)>1024 then return false end
    end
    return true
end

-- Prepare only the selected biome. No map payloads are shipped in the small package.
-- A fresh process verifies input/output hashes once per biome per game session.
local preparedMaps={}
function R.PrepareMap(world)
    local manager=world.parkLoadSaveManager
    if not manager then return true end
    local request=manager.tLoadParkFromFileRequest
    local token=manager.tLoadParkFromSaveTokenRequest
    local biome
    local names={temperatesandbox="temperate",tropicalsandbox="tropical",
        taigasandbox="taiga",mediterraneansandbox="mediterranean"}
    if request and g.type(request.sFileName)=="string" then
        local name=request.sFileName:lower():match("^/run/parks/sandbox/([^/]+)%.bin$")
        biome=names[name]
    elseif token and token.cSaveToken and g.type(api.save.GetSaveMetadata)=="function" then
        if g.type(api.save.IsSaveToken)=="function" and not api.save.IsSaveToken(token.cSaveToken) then return true end
        local ok,metadata=g.pcall(api.save.GetSaveMetadata,token.cSaveToken)
        local save=ok and metadata and metadata.tSave
        local mode=save and g.tostring(save.sGameMode):lower()
        if save and save.parkExpansions and (mode=="sandbox" or mode=="challenge") then
            local candidate=g.tostring(save.sGeome):lower()
            for _,allowed in g.pairs(names) do if candidate==allowed then biome=candidate end end
        end
    end
    if not biome or preparedMaps[biome] then return true end
    local function fail(message)
        R.LoadingProgress(false,0,"")
        world.parkExpansionsMapFailed=true
        world.parkExpansionsAutoError=g.tostring(message)
        return false
    end
    if not g.package or g.type(g.package.loadlib)~="function" then
        return fail("Terrain preparation component is unavailable.")
    end
    local loaded,begin,message=g.pcall(g.package.loadlib,
        "Win64/ovldata/Mod_BoundaryLab/Compatibility/ParkExpansionsBridge.dll","Begin")
    if not loaded or g.type(begin)~="function" then return fail("Could not load terrain preparation component: "..g.tostring(message or begin)) end
    local nonce=g.tostring(g.math.random(1,1000000000)).."-"..g.tostring(g.math.random(1,1000000000))
    local base="Win64/ovldata/Mod_BoundaryLab/AutoConversion/"
    local function read(path)
        local chunk=g.loadfile(path,"t",{})
        if not chunk then return end
        local ok,value=g.pcall(chunk)
        if ok and g.type(value)=="table" then return value end
    end
    R.LoadingProgress(true,0,"Preparing terrain…")
    local ok,errorMessage=g.pcall(begin,"__prepare_map__","Terrain preparation",biome,nonce)
    if not ok then return fail(errorMessage) end
    local bridge=read(base.."BridgeInfo.lua")
    if not bridge or bridge.version~=32 or bridge.supported~=true then
        return fail(bridge and bridge.message or "Terrain preparation bridge did not initialize.")
    end
    local accepted=read(base.."State-"..nonce..".lua")
    if not accepted or accepted.status=="error" then
        return fail(accepted and accepted.message or "Terrain preparation request was not accepted.")
    end
    local index=1
    -- Coroutine yields keep the native loading screen responsive during generation.
    for frame=1,108000 do
        local result=read(base.."Result-"..nonce..".lua")
        if not result then
            result=read(base.."Progress-"..nonce.."-"..index..".lua")
            if result then index=index+1 end
        end
        if result and result.status=="map_ready" then
            local expected=biome:sub(1,1):upper()..biome:sub(2).."Sandbox.bin"
            if result.filename~=expected then return fail("Prepared terrain response did not validate.") end
            preparedMaps[biome]=true
            R.LoadingProgress(false,100,"Terrain ready")
            world.boundaryLabProgress=0
            return true
        elseif result and result.status=="error" then return fail(result.message)
        elseif result then
            world.boundaryLabProgress=result.progress or 0
            world.boundaryLabMessage=result.message or "Preparing terrain…"
            R.LoadingProgress(true,result.progress,world.boundaryLabMessage)
        end
        g.coroutine.yield()
    end
    return fail("Terrain preparation is still running. Try loading the park again after it finishes.")
end

-- The C-module only starts the bundled worker. It never writes game memory.
-- Conversion completes before the native loader sees any world data.
function R.AutoConvert(world)
    local manager=world.parkLoadSaveManager
    local request=manager and manager.tLoadParkFromSaveTokenRequest
    if not request or not request.cSaveToken or g.type(api.save.GetSaveMetadata)~="function" then return end
    if g.type(api.save.IsSaveToken)=="function" and not api.save.IsSaveToken(request.cSaveToken) then return end
    local ok,metadata=g.pcall(api.save.GetSaveMetadata,request.cSaveToken)
    local save=ok and metadata and metadata.tSave
    if not save or save.parkExpansions then return end
    local mode=g.tostring(save.sGameMode):lower()
    local biomes={temperate=true,tropical=true,taiga=true,mediterranean=true}
    local biome=g.tostring(save.sGeome):lower()
    if (mode~="sandbox" and mode~="challenge") or not biomes[biome] then return end
    local function fail(message)
        R.LoadingProgress(false,0,"")
        world.parkExpansionsAutoError=g.tostring(message)
        world.boundaryLabProgress=0
    end
    if not g.package or g.type(g.package.loadlib)~="function"
        or g.type(api.save.GetSaveIdentifier)~="function" then
        fail("Automatic conversion component is unavailable; original park loaded unchanged.");return
    end
    local loaded,begin,message=g.pcall(g.package.loadlib,
        "Win64/ovldata/Mod_BoundaryLab/Compatibility/ParkExpansionsBridge.dll","Begin")
    if not loaded or g.type(begin)~="function" then
        fail("Automatic conversion component could not load: "..g.tostring(message or begin));return
    end
    local nonce=g.tostring(g.math.random(1,1000000000)).."-"..g.tostring(g.math.random(1,1000000000))
    local base="Win64/ovldata/Mod_BoundaryLab/AutoConversion/"
    local function read(path)
        local chunk=g.loadfile(path,"t",{})
        if not chunk then return end
        local success,value=g.pcall(chunk)
        if success and g.type(value)=="table" then return value end
    end
    R.LoadingProgress(true,0,"Preparing park…")
    local started,errorMessage=g.pcall(begin,g.tostring(api.save.GetSaveIdentifier(request.cSaveToken)),
        g.tostring(metadata.sName or save.sParkName or ""),biome,nonce)
    if not started then fail(errorMessage);return end
    local bridge=read(base.."BridgeInfo.lua")
    if not bridge or bridge.version~=32 or bridge.supported~=true then
        fail(bridge and bridge.message or "Automatic conversion bridge did not initialize. Original park unchanged.");return
    end
    local path=base.."State-"..nonce..".lua"
    local accepted=read(path)
    if not accepted then fail("Automatic conversion request was not accepted. Original park unchanged.");return end
    if accepted.status=="error" then fail(accepted.message);return end
    local progressIndex=1
    for frame=1,36000 do
        -- The worker publishes immutable files. Never keep polling a pathname
        -- that another process has to replace while Windows holds it open.
        local result=read(base.."Result-"..nonce..".lua")
        if not result then
            result=read(base.."Progress-"..nonce.."-"..progressIndex..".lua")
            if result then progressIndex=progressIndex+1 end
        end
        if result and result.status=="ready" then
            local hash=result.native and result.native:match(
                "^/run/Win64/ovldata/Mod_BoundaryLab/AutoConversion/([a-f0-9]+)%.bin$")
            if not hash or #hash~=64 or not validConvertedInfo(result.info) then
                fail("Converted world response did not validate. Original park unchanged.");return
            end
            -- File loading clears the active save token too: Save opens Save As
            -- instead of overwriting the old park. Keep its mode and native data.
            manager.tLoadParkFromFileRequest={sFileName=result.native,
                sTerrainFileName="/run/Win64/ovldata/Mod_BoundaryLab/Maps/"..result.info.filename:gsub("%.bin$",".trn"),
                bAllowMissingTerrain=false}
            manager.tLoadParkFromSaveTokenRequest=nil
            manager.cLastActiveParkSaveToken=nil
            world.parkExpansionsAutoInfo=result.info
            R.LoadingProgress(false,100,"Park conversion successful.")
            world.parkExpansionsAutoStatus="Park conversion successful."
            world.boundaryLabProgress=0
            return
        elseif result and result.status=="skip" then
            R.LoadingProgress(false,100,"")
            return
        elseif result and result.status=="error" then
            fail(result.message);return
        elseif result then
            -- Native park APIs and the new HUD are not ready yet. Keep load
            -- progress here without querying points or advancing a HUD wrapper.
            world.boundaryLabProgress=result.progress or 0
            world.boundaryLabMessage=result.message or "Converting existing park…"
            R.LoadingProgress(true,result.progress,world.boundaryLabMessage)
        end
        g.coroutine.yield()
    end
    fail("Automatic conversion timed out. Original park loaded unchanged; try again after conversion finishes.")
end

-- Converted saves opt in through metadata written on a separate archive copy.
-- The preset underlay must be extended BEFORE the native park load begins.
function R.ReadConvertedSave(world)
    local manager=world.parkLoadSaveManager
    local request=manager and (manager.tLoadParkFromSaveTokenRequest or manager.tLoadParkFromFileRequest)
    if not request then return end
    local info=world.parkExpansionsAutoInfo
    if not info then
        if not request.cSaveToken or g.type(api.save.GetSaveMetadata)~="function" then return end
        local ok,metadata=g.pcall(api.save.GetSaveMetadata,request.cSaveToken)
        info=ok and metadata and metadata.tSave and metadata.tSave.parkExpansions
    end
    if not validConvertedInfo(info) then return end
    world.parkExpansionsConverted=info
    request.sTerrainFileName="/run/Win64/ovldata/Mod_BoundaryLab/Maps/"..info.filename:gsub("%.bin$",".trn")
end

function R.InstallCompatibilityHooks()
    g.require("forgeutils.hookmanager"):AddHook("Managers.ParkLoadSaveManager","GenerateCurrentParkMetaData",
        function(original,self,...)
            local metadata=original(self,...)
            local world=current
            local s=world and state(world)
            if s and s.managed and g.type(metadata)=="table" then
                metadata.tSave=metadata.tSave or {}
                local converted=world.parkExpansionsConverted
                local template=world.boundaryLabTemplate
                metadata.tSave.parkExpansions={version=1,filename=s.filename,
                    seed=s.seed or (template and template.seed),bounds=s.bounds or (template and template.bounds),
                    sourceHash=converted and converted.sourceHash,sourceName=converted and converted.sourceName}
            end
            return metadata
        end)
end

function R.BeforeLoad(world)
    current=world
    R.LoadConfig(world)
    local mapOK,mapResult=g.pcall(R.PrepareMap,world)
    if not mapOK or mapResult==false then
        world.parkExpansionsMapFailed=true
        R.LoadingProgress(false,0,"")
        world.parkExpansionsAutoError=world.parkExpansionsAutoError or g.tostring(mapResult)
        -- Never throw before CPTWorld.OnLoad has initialized its managers.
        -- A fresh park can safely fall back to its original unexpanded template.
    end
    if not world.parkExpansionsMapFailed then
        local autoOK,autoError=g.pcall(R.AutoConvert,world)
        if not autoOK then R.LoadingProgress(false,0,"");world.parkExpansionsAutoError="Automatic conversion failed: "..g.tostring(autoError) end
        R.ReadConvertedSave(world)
    end
    state(world)
    local serial=api.world.GetWorldAPIs().worldserialisation
    if not serial or world.boundaryLabRegistered then return end
    serial:RegisterWorldSerialisationClient("BoundaryLabResearch",1,
        function(save)
            local s=state(world)
            save.managed=s.managed;save.width=s.width;save.height=s.height
            save.filename=s.filename;save.seed=s.seed;save.bounds=s.bounds;save.history=s.history
        end,
        function(load)
            -- Original templates and pre-research saves have no custom data.
            if not load or (load.width==nil and load.height==nil) then return true end
            g.assert(g.type(load.width)=="number" and load.width%1==0 and load.width>=0 and load.width<=5,"Invalid saved width research")
            g.assert(g.type(load.height)=="number" and load.height%1==0 and load.height>=0 and load.height<=5,"Invalid saved height research")
            world.boundaryLabResearch={managed=load.managed==true,width=load.width,height=load.height,
                filename=load.filename,seed=load.seed,bounds=load.bounds,history=load.history}
            return true
        end,
        function(version) return version==0 or version==1 end)
    world.boundaryLabRegistered=true
end

function R.AfterLoad(world,templates)
    local s=state(world)
    local converted=world.parkExpansionsConverted
    if world.parkExpansionsMapFailed then
        s.managed=false
        world.parkExpansionsUnsupportedReason=world.parkExpansionsAutoError
        world.boundaryLabMessage=world.parkExpansionsAutoError
        R.Push()
        return
    end
    if not s.managed and converted then
        local template=templates[("/run/parks/sandbox/"..converted.filename):lower()]
        local terrain=api.world.GetWorldAPIs().voxelterrain
        local a,b=terrain:GetWorldBounds(terrain:GetPrimaryVoxelTerrainEntityID())
        if template and a:GetX()==-1024 and a:GetY()==-2304 and a:GetZ()==-1024
            and b:GetX()==1023 and b:GetY()==2303 and b:GetZ()==1023 then
            s.managed=true;s.filename=converted.filename;s.seed=converted.seed;s.bounds=converted.bounds
            world.boundaryLabTemplate=template
            world.boundaryLabTerrainCreated=true
            world.boundaryLabFilename=converted.filename
        else
            world.parkExpansionsUnsupportedReason="Converted terrain did not validate. Expansion purchases remain unavailable."
        end
    end
    if world.boundaryLabTerrainCreated then
        s.managed=true;s.filename=world.boundaryLabFilename
    elseif s.managed and s.filename then
        local template=templates[("/run/parks/sandbox/"..s.filename):lower()]
        local w=api.world.GetWorldAPIs()
        local a,b=w.voxelterrain:GetWorldBounds(w.voxelterrain:GetPrimaryVoxelTerrainEntityID())
        if template and a:GetX()==-1024 and b:GetX()==1023 and b:GetY()==2303 then
            world.boundaryLabTemplate=template
            world.boundaryLabTerrainCreated=true
        else
            s.managed=false
            world.parkExpansionsUnsupportedReason="This saved park uses an incompatible terrain format. Expansion purchases are unavailable."
        end
    end
    if not s.managed then
        world.parkExpansionsUnsupportedReason=world.parkExpansionsUnsupportedReason
            or world.parkExpansionsAutoError
            or "This park is not registered with Park Expansions. Expansion purchases are unavailable; no points are spent."
        world.boundaryLabMessage=world.parkExpansionsUnsupportedReason
    end
    if s.managed then
        world.boundaryLabActiveSeed=s.seed
        world.boundaryLabExpectedBounds=s.bounds
        contours(world,world.boundaryLabTemplate)
        if settings(world).ResearchEnabled==false then
            R.QueueManual(world)
        else
            local ok,message=g.pcall(R.ApplyHeight,world,s.height)
            world.boundaryLabMessage=settings(world).error or (ok and "Choose an upgrade in Research > Park Expansions."
                or "Height setup failed: "..g.tostring(message)..". Use Apply Height to retry.")
            world.parkExpansionsHeightError=not ok and g.tostring(message) or nil
        end
        if world.parkExpansionsAutoStatus and not world.parkExpansionsHeightError
            and not settings(world).error and settings(world).ResearchEnabled~=false then
            world.boundaryLabMessage=world.parkExpansionsAutoStatus
        end
    end
    R.Push()
end

local function release(world)
    if world.boundaryLabSaveControl then
        world.boundaryLabSaveControl:ResumeSave()
        world.boundaryLabSaveControl=nil
    end
end

function R.Finish(world,success,message)
    local purchase=world.boundaryLabPurchase
    if not purchase then return end
    local s=state(world)
    if success then
        if purchase.branch~="manual" then s[purchase.branch]=purchase.level end
        if purchase.branch=="width" or purchase.branch=="manual" then
            local result=world.boundaryLabCommitResult
            g.assert(result,"Boundary commit did not return its contour")
            s.history=s.history or {}
            if s.seed and not purchase.restore then s.history[#s.history+1]={seed=s.seed,bounds=s.bounds} end
            s.seed=result.seed;s.bounds=result.bounds
            world.boundaryLabActiveSeed=s.seed;world.boundaryLabExpectedBounds=s.bounds
            contours(world,world.boundaryLabTemplate)
        end
        world.boundaryLabMessage=purchase.branch=="manual" and
            (message or ("Configured park limits applied."..(settings(world).warning and " "..settings(world).warning or ""))) or "Upgrade applied."
        world.boundaryLabProgress=100
    else
        if purchase.cost>0 then
            api.world.GetWorldAPIs().techtree:SetResearchPoints(points()+purchase.cost)
        end
        world.boundaryLabMessage=message or "Expansion cancelled. Research points refunded."
    end
    world.boundaryLabPurchase=nil
    world.boundaryLabResearchBusy=false
    release(world)
    R.Push()
end

function R.Request(branch,level)
    local world=current
    if not world or (branch~="width" and branch~="height") then return end
    if settings(world).ResearchEnabled==false then return end
    if not state(world).managed then
        world.boundaryLabMessage=world.parkExpansionsUnsupportedReason or "Expansion purchases are unavailable for this park. No points were spent."
        R.Push()
        return
    end
    local s=state(world)
    level=g.tonumber(level)
    local restore=level==s[branch] and s[branch]>0
    if not s.managed or world.boundaryLabResearchBusy or world.boundaryLabTask
        or (not restore and level~=s[branch]+1) or level<1 or level>5 or api.undo.IsBusy() then return end
    local cost=(restore or free(world)) and 0 or R.Costs[level]
    if points()<cost then world.boundaryLabMessage="Not enough research points.";R.Push();return end
    -- Hold manual and automatic saves only for the duration of this purchase.
    -- A preview and its reserved research points must never be serialized.
    local control=api.save.CreateSaveSuspensionControl()
    control:SuspendSave(api.player.GetGameOwner())
    world.boundaryLabSaveControl=control
    if cost>0 then api.world.GetWorldAPIs().techtree:SetResearchPoints(points()-cost) end
    world.boundaryLabPurchase={branch=branch,level=level,cost=cost,restore=restore}
    world.boundaryLabResearchBusy=true
    world.boundaryLabRecovering=nil
    world.boundaryLabProgress=0
    world.boundaryLabCommitResult=nil
    R.Progress(world,1,"Preparing expansion…")
    world.boundaryLabQueued=true
end

function R.QueueManual(world)
    local config=settings(world)
    if config.ResearchEnabled~=false or not state(world).managed or world.boundaryLabPurchase then return end
    local control=api.save.CreateSaveSuspensionControl()
    control:SuspendSave(api.player.GetGameOwner())
    world.boundaryLabSaveControl=control
    world.boundaryLabPurchase={branch="manual",cost=0,size=config.ManualParkSize,maximum=config.ManualMaxHeight}
    world.boundaryLabResearchBusy=true
    world.boundaryLabRecovering=nil
    world.boundaryLabProgress=0
    world.boundaryLabCommitResult=nil
    world.boundaryLabMessage="Applying configured park limits…"
    world.boundaryLabQueued=true
end

function R.Report()
    if not current then return end
    local s=state(current)
    local terrainOK,terrainBounds=g.pcall(function()
        local terrain=api.world.GetWorldAPIs().voxelterrain
        local minimum,maximum=terrain:GetWorldBounds(terrain:GetPrimaryVoxelTerrainEntityID())
        return g.tostring(minimum).." .. "..g.tostring(maximum)
    end)
    local report="Park Expansions 0.41 research report\nWIDTH_LEVEL="..s.width.." HEIGHT_LEVEL="..s.height
        .."\nTERRAIN_BOUNDS="..g.tostring(terrainBounds)
        .."\nTERRAIN_QUERY_OK="..g.tostring(terrainOK)
        .."\nCONVERTED_SAVE="..g.tostring(current.parkExpansionsConverted~=nil)
        .."\nAUTO_CONVERSION="..g.tostring(current.parkExpansionsAutoStatus)
        .."\nAUTO_CONVERSION_ERROR="..g.tostring(current.parkExpansionsAutoError)
        .."\nSOURCE_TEMPLATE="..g.tostring(s.filename)
        .."\nUNSUPPORTED_REASON="..g.tostring(current.parkExpansionsUnsupportedReason)
        .."\nHEIGHT_CONSTRAINT=invisible ceiling exclusion box"
        .."\nHEIGHT_VOLUME="..g.tostring(current.parkExpansionsHeightEntity)
        .."\nHEIGHT_SETUP_ERROR="..g.tostring(current.parkExpansionsHeightError)
        .."\nMANAGED="..g.tostring(s.managed).."\nHEIGHT_TOP="..g.tostring(current.parkExpansionsHeightTop)
        .."\nRESEARCH_ENABLED="..g.tostring(settings(current).ResearchEnabled)
        .."\nMANUAL_SIZE="..g.tostring(settings(current).ManualParkSize)
        .."\nMANUAL_HEIGHT="..g.tostring(settings(current).ManualMaxHeight)
        .."\nCONFIG_WARNING="..g.tostring(settings(current).warning)
        .."\nCONFIG_ERROR="..g.tostring(settings(current).error)
        .."\nLOADING_UI_DRIVER="..g.tostring(loadingDiagnostics.driver)
        .."\nLOADING_UI_WORLD_TICKS="..g.tostring(loadingDiagnostics.worldTicks or 0)
        .."\nLOADING_UI_TICKS="..g.tostring(loadingDiagnostics.ticks or 0)
        .."\nLOADING_UI_ROUTED="..g.tostring(loadingDiagnostics.routed)
        .."\nLOADING_UI_VIEWS="..g.tostring(loadingDiagnostics.views)
        .."\nLOADING_UI_READY="..g.tostring(loadingDiagnostics.ready)
        .."\nLOADING_UI_UPDATES="..g.tostring(loadingDiagnostics.updates)
        .."\nLOADING_UI_LAST_PERCENT="..g.tostring(loadingDiagnostics.lastPercent)
        .."\nLOADING_UI_ERROR="..g.tostring(loadingDiagnostics.error)
        .."\n"..(current.boundaryLabReport or current.boundaryLabMessage or "")
    api.world.GetWorldAPIs().editors:CopyToClipboard(report)
    current.boundaryLabMessage="Report copied. Paste it into chat with Ctrl+V."
    R.Push()
end

function R.Advance(world,expand)
    if world.boundaryLabQueued then
        if api.undo.IsBusy() then return end
        world.boundaryLabQueued=nil
        local p=world.boundaryLabPurchase
        world.boundaryLabTask=g.coroutine.create(function()
            if p.branch=="manual" then
                local s=state(world)
                local bounds=s.bounds
                local half=p.size/2
                local matches=bounds and g.math.abs(bounds[1]+half)<0.1 and g.math.abs(bounds[2]-half)<0.1
                    and g.math.abs(bounds[3]+half)<0.1 and g.math.abs(bounds[4]-half)<0.1
                if matches then
                    p.restore=true
                    world.boundaryLabCommitResult={seed=s.seed,bounds=bounds}
                else expand(world,p.size,true) end
                g.assert(world.boundaryLabCommitResult,"Configured boundary was not applied")
                R.Progress(world,98,"Applying configured height…")
                g.coroutine.yield()
                R.ApplyHeight(world,nil,p.maximum)
                R.Finish(world,true)
            elseif p.branch=="width" then
                expand(world,R.Widths[p.level])
                R.Finish(world,world.boundaryLabCommitResult~=nil,"Boundary rejected. Research points refunded.")
            else
                R.Progress(world,40,"Applying height upgrade…")
                g.coroutine.yield()
                R.ApplyHeight(world,p.level)
                R.Progress(world,90,"Finishing upgrade…")
                g.coroutine.yield()
                R.Finish(world,true)
            end
        end)
    end
    world.boundaryLabUIFrames=(world.boundaryLabUIFrames or 0)+1
    if world.boundaryLabUIFrames%30==0 then R.Push() end
end

function R.Shutdown(world)
    if current==world then R.LoadingProgress(false,0,"") end
    if world.parkExpansionsHeightEntity then
        api.entity.DestroyEntity(world.parkExpansionsHeightEntity)
        world.parkExpansionsHeightEntity=nil
    end
    if world.boundaryLabPurchase then
        local p=world.boundaryLabPurchase
        R.Finish(world,world.boundaryLabCommitResult~=nil
            or (p.branch=="height" and world.boundaryLabHeightApplied==p.level),
            "Operation interrupted. Research points refunded.")
    end
    if world.boundaryLabRegistered then
        api.world.GetWorldAPIs().worldserialisation:UnregisterWorldSerialisationClient("BoundaryLabResearch")
    end
    release(world)
    if current==world then current=nil end
end

-- Stock terrain-relative markers cast only 1000 m downward and format a miss
-- as zero. Keep the original sampler, debug marker limit and widget lifecycle;
-- repair only zero results when a longer ray really finds ground below 1000 m.
function R.InstallHeightMarkerFix()
    g.require("forgeutils.hookmanager"):AddHook("Editors.Track.TrackHeightMarkerHelper","UpdateHeightMarkers",
        function(original,self,showingHeatmap,seaLevel)
            if self.sHeightMarkerMode~="hm_terrainrelative" or showingHeatmap then
                return original(self,showingHeatmap,seaLevel)
            end
            local manager=self.billboardUIManager
            local zeroInfos={}
            local proxy={}
            function proxy:SetBillboardWidgetUIInfo(kind,index,info)
                if kind==self.markerKind and info.nValue==0 then zeroInfos[index]=info end
                return manager:SetBillboardWidgetUIInfo(kind,index,info)
            end
            proxy.markerKind=self.nCoasterLabelWidgetID
            function proxy:SetBillboardWidgetData(kind,positions)
                if kind==self.markerKind and g.next(zeroInfos) then
                    local terrain=api.world.GetWorldAPIs().voxelterrain
                    local id=terrain:GetPrimaryVoxelTerrainEntityID()
                    local minimum=terrain:GetWorldBounds(id)
                    local Vector3=g.require("Vector3")
                    local UnitConversion=g.require("Helpers.UnitConversion")
                    for index,info in g.pairs(zeroInfos) do
                        local position=positions[index]
                        if position then
                            local depth=position:GetY()-minimum:GetY()+1
                            if depth>1000 then
                                local distance=terrain:CoarseRayCast(id,position,-Vector3.YAxis,depth)
                                if g.type(distance)=="number" and distance>1000 and distance<=depth then
                                    info.nValue=UnitConversion.Distance_ToUserPref(distance,UnitConversion.Distance_Metres)
                                    manager:SetBillboardWidgetUIInfo(kind,index,info)
                                end
                            end
                        end
                    end
                end
                return manager:SetBillboardWidgetData(kind,positions)
            end
            g.setmetatable(proxy,{__index=function(_,key)
                local value=manager[key]
                if g.type(value)=="function" then return function(_,...) return value(manager,...) end end
                return value
            end})
            self.billboardUIManager=proxy
            local ok,result=g.pcall(original,self,showingHeatmap,seaLevel)
            self.billboardUIManager=manager
            if not ok then g.error(result,0) end
            return result
        end)
end

function R.Init()
    api.ui2.MapResources("BoundaryLabUI")
    local uiHooks=g.require("forgeutils.uihookmanager")
    uiHooks:AddImportHook("HUD","/js/boundarylab/research.js")
    local hooks=g.require("forgeutils.hookmanager")
    -- The loading script is not a require() module in this build. Wrap the
    -- live game environment instead: BaseGame.AdvancePreWorld calls this
    -- instance's OnPhase dynamically, outside the park-loading coroutine.
    local ok,environment=g.pcall(function()return api.game.GetEnvironment()end)
    if ok and g.type(environment)=="table" and g.type(environment.OnPhase)=="function" then
        if not environment.parkExpansionsLoadingDriver then
            local phase=environment.OnPhase
            environment.OnPhase=function(self,name,...)
                local result=phase(self,name,...)
                if name=="Advance" then
                    local success,message=g.pcall(R.AdvanceGlobalLoading)
                    if not success then loadingDiagnostics.error=g.tostring(message) end
                end
                return result
            end
            environment.parkExpansionsLoadingDriver=true
        end
        loadingDiagnostics.driver=true
    else
        loadingDiagnostics.driver=false
        loadingDiagnostics.error="Game environment Advance callback was unavailable."
    end
    hooks:AddHook("UI.GamefaceUIWrapper","_OnReadyCallback",function(original,self,...)
        local result=original(self,...)
        if self.tInitSettings.sViewName=="HUD" and not wrappers[self] then
            wrappers[self]=true
            self:AddEventListener("BoundaryLab_RequestState",0,R.Push,nil)
            self:AddEventListener("BoundaryLab_Purchase",2,R.Request,nil)
            self:AddEventListener("BoundaryLab_Report",0,R.Report,nil)
        end
        return result
    end)
    hooks:AddHook("UI.GamefaceUIWrapper","Shutdown",function(original,self,...)
        wrappers[self]=nil
        loadingWrappers[self]=nil
        return original(self,...)
    end)
end

return R
