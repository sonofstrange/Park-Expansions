-- Convert the original backdrop placements into ordinary, saved scenery parts.
local g=_G
local api=g.api
local S={}
local clusters={
    {"NAT_Tree_Conifer_Larch_European_Cluster_01","NAT_Tree_Conifer_Larch_European_Large_01"},
    {"NAT_Tree_Conifer_Larch_European_Cluster_02","NAT_Tree_Conifer_Larch_European_Large_01"},
    {"NAT_Tree_Conifer_Pine_Aleppo_Cluster_01","NAT_Tree_Conifer_Pine_Aleppo_Large_01"},
    {"NAT_Tree_Conifer_Pine_Aleppo_Cluster_02","NAT_Tree_Conifer_Pine_Aleppo_Large_01"},
    {"NAT_Tree_Broadleaf_Olive_Cluster_01","NAT_Tree_Broadleaf_Olive_Large_01"},
    {"NAT_Tree_Broadleaf_Olive_Cluster_02","NAT_Tree_Broadleaf_Olive_Large_01"},
    {"NAT_Bush_Creosote_Flowerless_Cluster_01","NAT_Bush_Creosote_Flowerless_Large_01"},
}

local clusterModels={
    NAT_Tree_Conifer_Larch_European_Cluster_01="nat_tree_conifer_larch_european_cluster_01_skirt",
    NAT_Tree_Conifer_Larch_European_Cluster_02="nat_tree_conifer_larch_european_cluster_02_skirt",
    NAT_Tree_Conifer_Pine_Aleppo_Cluster_01="nat_tree_conifer_pine_aleppo_cluster_01_skirt",
    NAT_Tree_Conifer_Pine_Aleppo_Cluster_02="nat_tree_conifer_pine_aleppo_cluster_02_skirt",
    NAT_Tree_Broadleaf_Olive_Cluster_01="nat_tree_broadleaf_olive_cluster_01_skirt",
    NAT_Tree_Broadleaf_Olive_Cluster_02="nat_tree_broadleaf_olive_cluster_02_skirt",
    NAT_Bush_Creosote_Flowerless_Cluster_01="nat_bush_creosote_flowerless_cluster_01_skirt",
}

local function ensureCompiled(name)
    if not api or not api.entity or g.type(api.entity.FindPrefab)~="function" then return false end
    if api.entity.FindPrefab(name) then return true end
    local ok,module=g.pcall(g.require,name)
    if not ok or not module then
        ok,module=g.pcall(g.require,name:lower())
    end
    if ok and module and g.type(module.GetRoot)=="function" and g.type(api.entity.CompilePrefab)=="function" then
        g.pcall(api.entity.CompilePrefab,module.GetRoot(),name)
    end
    return (api.entity.FindPrefab(name) and true) or false
end

local function registerPrefab(add,name,root)
    -- Native prefab resolution also uses Lua modules, including on a later
    -- rebuild. Match ForgeUtils.PrefabUtility's root/flattened-root contract.
    local module={GetRoot=function()return root end}
    module.GetFlattenedRoot=function()
        local prefab=api.entity.FindPrefab(name)
        if not prefab and api.entity.CompilePrefab(root,name) then prefab=api.entity.FindPrefab(name) end
        return prefab
    end
    local loader=function() return module end
    g.package.loaded[name]=module
    g.package.loaded[name:lower()]=module
    if g.package.preload then
        g.package.preload[name]=loader
        g.package.preload[name:lower()]=loader
    end
    if add then add(name,root) end
    if api and api.entity and g.type(api.entity.CompilePrefab)=="function" then
        g.pcall(api.entity.CompilePrefab,root,name)
    end
end

function S.AddPrefabs(add)
    for _,entry in g.ipairs(clusters) do
        ensureCompiled(entry[2].."_Game")
        ensureCompiled(entry[2])
        local ok,sourceModule=g.pcall(g.require,entry[1].."_Skirt")
        if not ok or not sourceModule or g.type(sourceModule.GetRoot)~="function" then
            ok,sourceModule=g.pcall(g.require,(entry[1].."_Skirt"):lower())
        end
        local source=ok and sourceModule and g.type(sourceModule.GetRoot)=="function" and sourceModule.GetRoot()
        local model=source and source.Properties and source.Properties.ModelName and source.Properties.ModelName.Default
            or clusterModels[entry[1]]
        local pkg=source and source.Components and source.Components.AssetPackageLoader
        if not pkg then
            local pok,pMod=g.pcall(g.require,entry[2].."_Game")
            local pRoot=pok and pMod and g.type(pMod.GetRoot)=="function" and pMod.GetRoot()
            pkg=pRoot and pRoot.Components and pRoot.Components.AssetPackageLoader
        end
        -- Retain the cluster's actual mesh and asset package, with the ordinary
        -- game's interaction/render components so it can be selected and moved.
        local root={Prefab=entry[2].."_Game",Components={
            Model={ModelName=model},AssetPackageLoader=pkg}}
        registerPrefab(add,"PE_"..entry[1],root)
        -- Both entry points inherit the stock gameplay prefab directly. Avoid
        -- a second custom inheritance hop during native preview construction.
        registerPrefab(add,"PE_"..entry[1].."_Game",root)
    end
end

function S.Init()
    local Builder=g.require("forgeutils.builders.scenerypartbuilder")
    for _,entry in g.ipairs(clusters) do
        local part=Builder.new():asSimplePart():withID("PE_"..entry[1])
            :withVisualPrefab("PE_"..entry[1]):withScaleRange(0.2,5)
            :withNameFile("BuildingPartName_"..entry[2])
            :withDescriptionFile("BuildingPartName_"..entry[2])
        -- Existing clusters are restored, rather than added to the scenery browser.
        part:addToDB()
    end
end

function S.BeforeLoad(world)
    S.AddPrefabs()
    world.parkExpansionsScenery={complete=false,count=0}
    local serial=api.world.GetWorldAPIs().worldserialisation
    serial:RegisterWorldSerialisationClient("ParkExpansionsScenery",1,
        function(save)
            local state=world.parkExpansionsScenery
            save.complete=state.complete;save.count=state.count;save.source=state.source;save.nextIndex=state.nextIndex
        end,
        function(load)
            if load and (load.complete==true or load.nextIndex) then
                world.parkExpansionsScenery={complete=load.complete==true,count=load.count or 0,
                    source=load.source,nextIndex=load.nextIndex}
            end
            return true
        end,
        function(version) return version==0 or version==1 end)
end

local function wait(test,message)
    for frame=1,10800 do
        if test() then return end
        g.coroutine.yield()
    end
    g.error(message)
end

local function validate(data,half)
    g.assert(data and data.version==1,"Original scenery data is unavailable")
    g.assert(not data.error,data.error)
    g.assert(g.type(data.source)=="string" and #data.source==64,"Invalid scenery source hash")
    g.assert(g.type(data.groups)=="table" and #data.groups<=100,"Invalid scenery groups")
    local count=0
    for _,group in g.ipairs(data.groups) do
        g.assert(g.type(group.resource)=="string" and #group.resource<128 and
            (group.resource:match("^NAT_[%w_]+$") or group.resource:match("^PE_NAT_[%w_]+$")),"Invalid scenery resource")
        g.assert(g.type(group.instances)=="table","Invalid scenery placements")
        for _,row in g.ipairs(group.instances) do
            g.assert(#row==4,"Invalid scenery transform")
            for _,value in g.ipairs(row) do
                g.assert(g.type(value)=="number" and value==value and g.math.abs(value)<10000,"Invalid scenery coordinate")
            end
            local edge=g.math.max(g.math.abs(row[1]),g.math.abs(row[3]))
            g.assert(edge>=512 and edge<half-4,"Scenery placement overlaps the original park or outer backdrop")
            count=count+1
            g.assert(count<=100000,"Too many scenery placements")
        end
    end
    return count
end

local function validatePreview(preview)
    local reasons,allowed
    for frame=1,600 do
        allowed=api.undo.CanCommitPreview(preview)
        reasons=api.undo.GetCommitFailReasons(preview)
        if allowed==true then return true,reasons end
        -- Like boundary placement, completion of the undo operation does not
        -- guarantee that asynchronous constraint checks have settled yet.
        if frame>=5 and allowed==false and reasons and not reasons.bUnknown then return false,reasons end
        g.coroutine.yield()
    end
    return false,reasons
end

local function onlyParkBounds(reasons)
    if not reasons or not reasons.bOutOfBounds or reasons.bOutOfBounds==0 then return false end
    for key,value in g.pairs(reasons) do
        if key~="bOutOfBounds" and value~=nil and value~=false and value~=0 then return false end
    end
    return true
end

local function rejectionDetails(reasons)
    local active={}
    for key,value in g.pairs(reasons or {}) do
        if value~=false and value~=nil and value~=0 then
            active[#active+1]=g.tostring(key).."="..g.tostring(value)
        end
    end
    g.table.sort(active)
    return #active>0 and g.table.concat(active,", ") or "no active reason flags reported"
end

function S.AfterLoad(world,progress)
    S.AddPrefabs()
    local state=world.parkExpansionsScenery
    if not state or state.complete then return end
    local research=world.boundaryLabResearch or {}
    local converted=world.parkExpansionsConverted
    local filename=world.boundaryLabFilename or research.filename or (converted and converted.filename)
    if not (world.boundaryLabTerrainCreated or research.managed or converted) then return end
    if not filename or not filename:match("^%a+Sandbox%.bin$") then return end
    local w=api.world.GetWorldAPIs()
    local a,b=w.voxelterrain:GetWorldBounds(w.voxelterrain:GetPrimaryVoxelTerrainEntityID())
    local half=(world.parkExpansionsTerrainSize or 2048)/2
    if a:GetX()~=-half or a:GetZ()~=-half or b:GetX()~=half-1 or b:GetZ()~=half-1 then return end
    local preview,changedConstraints,saveControl
    local ok,message=g.pcall(function()
        local chunk=g.assert(g.loadfile("Win64/ovldata/Mod_BoundaryLab/"..(half==2048 and "Maps4096" or "Maps").."/"..
            filename:gsub("%.bin$",".decor.lua"),"t",{}),"Original scenery cache is missing")
        local data=chunk()
        local count=validate(data,half)
        for _,group in g.ipairs(data.groups) do
            for _,row in g.ipairs(group.instances) do
                g.assert(row[1]>=a:GetX() and row[1]<=b:GetX() and row[2]>=a:GetY() and row[2]<=b:GetY()
                    and row[3]>=a:GetZ() and row[3]<=b:GetZ(),"Original scenery exceeds the physical terrain volume")
            end
        end
        local Vector3=g.require("Vector3")
        local TransformQ=g.require("TransformQ")
        local Quaternion=g.require("Quaternion")
        local placements={}
        for _,group in g.ipairs(data.groups) do
            local gameplay=group.resource.."_Game"
            local available=ensureCompiled(gameplay)
            if not available then
                for _,cl in g.ipairs(clusters) do
                    if group.resource=="PE_"..cl[1] then
                        available=ensureCompiled(cl[2].."_Game")
                        break
                    end
                end
            end
            g.assert(available,"Scenery gameplay prefab is unavailable: "..gameplay)
            if not ensureCompiled(group.resource) then
                for _,cl in g.ipairs(clusters) do
                    if group.resource=="PE_"..cl[1] then
                        ensureCompiled(cl[2])
                        break
                    end
                end
            end
            for _,row in g.ipairs(group.instances) do
                placements[#placements+1]={resource=group.resource,row=row}
            end
        end
        local cursor=state.nextIndex or 1
        g.assert(g.type(cursor)=="number" and cursor%1==0 and cursor>=1 and cursor<=count+1,
            "Invalid scenery continuation")
        g.assert(cursor==1 or state.source==data.source,"Original scenery changed during an incomplete import")
        saveControl=api.save.CreateSaveSuspensionControl()
        saveControl:SuspendSave(api.player.GetGameOwner())
        world.parkExpansionsScenerySaveControl=saveControl
        -- Native scenery previews belong to the activated park. Submit bounded
        -- transactions and finish each one before requesting another batch.
        w.park:DeactivateParkEditConstraints()
        changedConstraints=true
        world.parkExpansionsSceneryConstraints=true
        local refundCategory = (w and w.park and (w.park.ExpenditureCategory_SceneryConstruction or w.park.ExpenditureCategory_Rewards)) or 0
        while cursor<=count do
            wait(function()return not api.undo.IsBusy() end,"Scenery editor stayed busy")
            local last=g.math.min(cursor+127,count)
            local hierarchy=w.editors:CreateUndoOperationsHierarchy()
            hierarchy:SetCashAccumulate(false)
            local token=api.entity.CreateRequestCompletionToken()
            local created={}
            for index=cursor,last do
                local entry=placements[index]
                local resName=entry.resource
                if not api.entity.FindPrefab(resName) then
                    for _,cl in g.ipairs(clusters) do
                        if resName=="PE_"..cl[1] and api.entity.FindPrefab(cl[2]) then
                            resName=cl[2]
                            break
                        end
                    end
                end
                created[#created+1]={object=hierarchy:CreateNewPart(resName,token),row=entry.row}
            end
            wait(function()return api.entity.HaveRequestsCompleted(token)end,"Scenery assets did not finish loading")
            for _,entry in g.ipairs(created) do
                local row=entry.row
                local edit=hierarchy:StartEditingPart_Scenery(entry.object)
                edit:SetTransform(TransformQ.FromOrPos(Quaternion.FromYawPitchRoll(Vector3:new(row[4],0,0)),
                    Vector3:new(row[1],row[2],row[3])))
            end
            local busy
            busy,preview=api.undo.PreviewChangeList(hierarchy:GetFullUndoChangeList())
            g.assert(preview,"Scenery preview was not created")
            world.parkExpansionsSceneryPreview=preview
            wait(function()return api.undo.IsOperationComplete(busy)end,"Scenery preview timed out")
            local allowed,reasons=validatePreview(preview)
            state.lastReasons=rejectionDetails(reasons)
            state.batchFirst=cursor;state.batchLast=last;state.batchResource=placements[cursor].resource
            local backgroundBounds=not allowed and onlyParkBounds(reasons)
            g.assert(allowed or backgroundBounds,"Engine rejected original scenery restoration: "..state.lastReasons..
                " (objects "..cursor..".."..last..", "..state.batchResource..")")
            -- CPTWorld.SpawnScenery_ConsoleCommand uses CommitPreview after
            -- validation settles without requiring CanCommitPreview to be true.
            -- This exception restores original backdrop inside the verified voxel
            -- volume; it does not unlock plots or permit other validation failures.
            local money=w.money
            local cashBefore=money and g.type(money.GetCash)=="function" and money:GetCash() or nil
            local previousUnlimited
            if money and g.type(money.SetUnlimitedCash)=="function" then
                g.assert(g.type(money.HasUnlimitedCash)=="function","Cannot read the original cash mode")
                previousUnlimited=money:HasUnlimitedCash()
                money:SetUnlimitedCash(true)
            end
            -- No coroutine yield while the temporary cash mode is active.
            local commitOK,committed=g.pcall(api.undo.CommitPreview,preview)
            if previousUnlimited~=nil then money:SetUnlimitedCash(previousUnlimited) end
            g.assert(commitOK,committed)
            g.assert(committed~=nil,"Original scenery commit did not start")
            if backgroundBounds then state.boundsBatches=(state.boundsBatches or 0)+1 end
            preview=nil;world.parkExpansionsSceneryPreview=nil
            -- Native save clients own committed objects. Record the continuation
            -- immediately, so an interrupted import cannot duplicate that batch.
            cursor=last+1
            state.nextIndex=cursor;state.count=last;state.source=data.source
            wait(function()return api.undo.IsOperationComplete(committed)end,"Scenery commit timed out")
            wait(function()return not api.undo.IsBusy()end,"Scenery commit stayed busy")
            if w and w.money and cashBefore and g.type(w.money.GetCash)=="function" and g.type(w.money.ModifyCash)=="function" then
                local currentCash = w.money:GetCash()
                local spent = cashBefore - currentCash
                if spent > 0 then
                    w.money:ModifyCash(spent, refundCategory)
                end
            end
            progress(true,g.math.floor(last*100/g.math.max(count,1)),"Restoring scenery: "..last.."/"..count)
            -- Give the native preview manager a full Advance between transactions.
            g.coroutine.yield()
        end
        state.complete=true;state.count=count;state.source=data.source

    end)
    if preview then
        local cancelled,cancelError=g.pcall(function()
            local token=api.undo.CancelPreview(preview)
            wait(function() return api.undo.IsOperationComplete(token) end,"Scenery cancellation timed out")
        end)
        if not cancelled then ok=false;message=g.tostring(message).."; "..g.tostring(cancelError) end
    end
    world.parkExpansionsSceneryPreview=nil
    if changedConstraints then w.park:ActivateParkEditConstraints() end
    world.parkExpansionsSceneryConstraints=nil
    if w then
        if w.scenery_editconstraint and g.type(w.scenery_editconstraint.ClearEditConstraintsForAllParts)=="function" then
            g.pcall(w.scenery_editconstraint.ClearEditConstraintsForAllParts,w.scenery_editconstraint)
        end
        if w.rides and g.type(w.rides.SetAllRidesEditable)=="function" then
            g.pcall(w.rides.SetAllRidesEditable,w.rides,true)
        end
        if api.track and g.type(api.track.ClearAllTrackEditConstraints)=="function" then
            g.pcall(api.track.ClearAllTrackEditConstraints)
        end
        if w.flumes and g.type(w.flumes.SetAllPlatformsEditable)=="function" then
            g.pcall(w.flumes.SetAllPlatformsEditable,w.flumes,true)
        end
    end
    if saveControl then saveControl:ResumeSave() end
    world.parkExpansionsScenerySaveControl=nil
    if not ok then
        state.error=g.tostring(message)
        api.debug.Trace("Park Expansions scenery: "..state.error)
    end
    progress(false,100,"")
end

-- OnLoad registers the save client only. Match the game's default spawn-point
-- placement: create objects from OnAdvance after OnActivate has completed.
function S.Queue(world)
    if world.parkExpansionsScenery and not world.parkExpansionsScenery.complete then
        world.parkExpansionsSceneryPending=true
    end
end

function S.Advance(world,progress)
    if not world.parkExpansionsSceneryPending and not world.parkExpansionsSceneryTask then return false end
    if world.fnGenerateSpawnPoint then return true end
    if not world.parkExpansionsSceneryTask then
        if api.undo.IsBusy() then return true end
        world.parkExpansionsSceneryPending=nil
        world.boundaryLabProgress=0
        world.parkExpansionsSceneryTask=g.coroutine.create(function()S.AfterLoad(world,progress)end)
    end
    local task=world.parkExpansionsSceneryTask
    local ok,message=g.coroutine.resume(task)
    if not ok then
        world.parkExpansionsScenery.error=g.tostring(message)
        S.Shutdown(world)
        progress(false,0,"Scenery restoration failed.")
    elseif g.coroutine.status(task)=="dead" then
        world.parkExpansionsSceneryTask=nil
    end
    return true
end

function S.Shutdown(world)
    world.parkExpansionsSceneryPending=nil
    world.parkExpansionsSceneryTask=nil
    if world.parkExpansionsSceneryPreview then
        api.undo.CancelPreview(world.parkExpansionsSceneryPreview)
        world.parkExpansionsSceneryPreview=nil
    end
    if world.parkExpansionsSceneryConstraints then
        api.world.GetWorldAPIs().park:ActivateParkEditConstraints()
        world.parkExpansionsSceneryConstraints=nil
    end
    if world.parkExpansionsScenerySaveControl then
        world.parkExpansionsScenerySaveControl:ResumeSave()
        world.parkExpansionsScenerySaveControl=nil
    end
end

return S
