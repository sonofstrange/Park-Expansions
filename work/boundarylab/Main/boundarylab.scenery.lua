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

function S.AddPrefabs(add)
    for _,entry in g.ipairs(clusters) do
        local source=g.require(entry[1].."_Skirt").GetRoot()
        local model=source.Properties.ModelName.Default
        -- Retain the cluster's actual mesh and asset package, with the ordinary
        -- game's interaction/render components so it can be selected and moved.
        local root={Prefab=entry[2].."_Game",Components={
            Model={ModelName=model},AssetPackageLoader=source.Components.AssetPackageLoader}}
        add("PE_"..entry[1],root)
        add("PE_"..entry[1].."_Game",{Prefab="PE_"..entry[1]})
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

local function validate(data)
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
            g.assert(edge>=512 and edge<1020,"Scenery placement overlaps the original park or outer backdrop")
            count=count+1
            g.assert(count<=20000,"Too many scenery placements")
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
    local state=world.parkExpansionsScenery
    if not state or state.complete then return end
    local research=world.boundaryLabResearch or {}
    local converted=world.parkExpansionsConverted
    local filename=world.boundaryLabFilename or research.filename or (converted and converted.filename)
    if not (world.boundaryLabTerrainCreated or research.managed or converted) then return end
    if not filename or not filename:match("^%a+Sandbox%.bin$") then return end
    local w=api.world.GetWorldAPIs()
    local a,b=w.voxelterrain:GetWorldBounds(w.voxelterrain:GetPrimaryVoxelTerrainEntityID())
    if a:GetX()~=-1024 or a:GetZ()~=-1024 or b:GetX()~=1023 or b:GetZ()~=1023 then return end
    local preview,changedConstraints,saveControl
    local ok,message=g.pcall(function()
        local chunk=g.assert(g.loadfile("Win64/ovldata/Mod_BoundaryLab/Maps/"..
            filename:gsub("%.bin$",".decor.lua"),"t",{}),"Original scenery cache is missing")
        local data=chunk()
        local count=validate(data)
        local Vector3=g.require("Vector3")
        local TransformQ=g.require("TransformQ")
        local Quaternion=g.require("Quaternion")
        local placements={}
        for _,group in g.ipairs(data.groups) do
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
        while cursor<=count do
            wait(function()return not api.undo.IsBusy() end,"Scenery editor stayed busy")
            local last=g.math.min(cursor+127,count)
            local hierarchy=w.editors:CreateUndoOperationsHierarchy()
            hierarchy:SetCashAccumulate(false)
            local token=api.entity.CreateRequestCompletionToken()
            local created={}
            for index=cursor,last do
                local entry=placements[index]
                created[#created+1]={object=hierarchy:CreateNewPart(entry.resource,token),row=entry.row}
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
            g.assert(allowed,"Engine rejected original scenery restoration: "..state.lastReasons..
                " (objects "..cursor..".."..last..", "..state.batchResource..")")
            local committed=api.undo.CommitPreview(preview)
            preview=nil;world.parkExpansionsSceneryPreview=nil
            -- Native save clients own committed objects. Record the continuation
            -- immediately, so an interrupted import cannot duplicate that batch.
            cursor=last+1
            state.nextIndex=cursor;state.count=last;state.source=data.source
            wait(function()return api.undo.IsOperationComplete(committed)end,"Scenery commit timed out")
            wait(function()return not api.undo.IsBusy()end,"Scenery commit stayed busy")
            api.undo.Checkpoint({})
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
