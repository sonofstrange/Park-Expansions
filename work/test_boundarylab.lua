-- Simulated engine checks. These do not establish compatibility with the real game.
local originalLoadfile, originalRequire, originalIO = loadfile, require, io
local source = "work/boundarylab/Main/database.mod_boundarylabluadatabase.lua"
local biomes = {
    ["temperatesandbox.bin"] = {seed={505.0637512207031,46.2103385925293,498.8643493652344},bounds={-500.7930603027344,505.0637512207031,-503.95611572265625,503.9422302246094}},
    ["tropicalsandbox.bin"] = {seed={-497.2756652832031,6.564492225646973,484.7773742675781},bounds={-499.1105651855469,509.46453857421875,-504.4102783203125,499.5578918457031}},
    ["taigasandbox.bin"] = {seed={-486.17913818359375,76.15367126464844,-486.6044006347656},bounds={-502.78826904296875,510.9080810546875,-511.0911560058594,413.6222229003906}},
    ["mediterraneansandbox.bin"] = {seed={-506.6679992675781,10.164406776428223,-502.89056396484375},bounds={-510.12164306640625,488.77117919921875,-507.6991882324219,510.1072692871094}},
}
local function test(name, parkName, allowCommit, mode, pendingKind, controlAccepted, alreadyExpanded, highGround, biome, groundMode, rectangleCase, widthRun)
    local template=biomes[biome or "temperatesandbox.bin"]
    local bounds=template.bounds
    if widthRun and widthRun.from>0 then
        local h=widthRun.from/2;bounds={-h,h,-h,h}
    end
    local targetHalf=widthRun and (widthRun.manual and widthRun.to/2 or math.min(widthRun.to/2,(widthRun.size or 2048)/2-4)) or 768
    local seedPoint=widthRun and widthRun.from>0 and {bounds[1],10,bounds[3]} or template.seed
    local rayTop=widthRun and 2304 or 1280
    local rayDepth=widthRun and 4609 or 2561
    local pointCalls = 0
    local groundHeight = highGround and 600 or (rectangleCase and 16 or 42)
    local function heightAt(x,z)
        if rectangleCase=="hills190" then return 16+55*math.sin(x/17)+30*math.cos(z/13) end
        return groundHeight
    end
    local committed,cancelled,queried,popupCount,editEnabled = 0,0,0,0,false
    local clipboardReport
    local trace = {}
    local V = {}
    function V:new(x,y,z)
        return {x=x,y=y,z=z,GetX=function(s) return s.x end,
            GetY=function(s) return s.y end,GetZ=function(s) return s.z end}
    end
    local function object(t)
        return {data=t,GetAllData=function(s) return s.data end,
            FillData=function(s,v) s.data=v end}
    end
    local posts,panels,selection = {},{},{tControlPosts={},tPanels={}}
    local initialScale = alreadyExpanded and 1.01 or 1
    local positions={{bounds[1],bounds[3]},{bounds[2],bounds[3]},
        {bounds[2],bounds[4]},{bounds[1],bounds[4]}}
    if rectangleCase=="concave190" or rectangleCase=="reverse190" or rectangleCase=="hills190" then
        positions={}
        local vertices={{bounds[1],bounds[3]},{bounds[2],bounds[3]},
            {bounds[2],bounds[4]},{0,bounds[4]-300},{bounds[1],bounds[4]}}
        for side=1,5 do
            local a,b=vertices[side],vertices[side%5+1]
            for j=0,37 do
                positions[#positions+1]={a[1]+(b[1]-a[1])*j/38,a[2]+(b[2]-a[2])*j/38}
            end
        end
        if rectangleCase=="reverse190" then
            local reverse={}
            for i=#positions,1,-1 do reverse[#reverse+1]=positions[i] end
            positions=reverse
        end
    end
    for i,p in ipairs(positions) do
        posts[i] = object({vPos=V:new(p[1]*initialScale,10,p[2]*initialScale),vDir=V:new(1,0,0),
            nWorldHeight=10.8,sBoundaryType="ParkBoundary"})
        selection.tControlPosts[posts[i]]=true
    end
    for i=1,#posts do
        local j=i%#posts+1
        panels[i] = object({vBasePosStart=posts[i].data.vPos,vBasePosEnd=posts[j].data.vPos,
            oStartControlPost=posts[i],oEndControlPost=posts[j],sBoundaryType="ParkBoundary",
            tSegmentData={old=true},nWorldHeightStart=10.8,nWorldHeightEnd=10.8})
        selection.tPanels[panels[i]]=true
    end
    if rectangleCase=="broken" then panels[1].data.oEndControlPost=posts[3] end
    local edits={posts={},panels={},addedPosts={},addedPanels={}}
    function edits:ChangeControlPost(old,new) self.posts[old]=new end
    function edits:ChangePanel(old,new) self.panels[old]=new end
    function edits:AddControlPost(post) self.addedPosts[#self.addedPosts+1]=post end
    function edits:AddPanel(panel) self.addedPanels[#self.addedPanels+1]=panel end
    function edits:HasChanges() return next(self.posts)~=nil end
    local hierarchy={GetBoundaryChangeList=function() return edits end,
        GetFullUndoChangeList=function() return edits end}
    local plotsUnlocked,plotRestrictionsCleared,enforcedAreaCleared,crowdTerrainID
    local w={}
    w.park={GetParkName=function() return parkName end,
        GetParkBoundaryPlotUIData=function() return {} end,
        UnlockAllPlots=function(_,flag) plotsUnlocked=flag end,
        ClearAllPlotRestrictions=function(_) plotRestrictionsCleared=true end,
        ClearEnforcedPlacementArea=function(_) enforcedAreaCleared=true end,
        IsPositionWithinParkBoundary=function(_,p)
            local scale = committed > 0 and 1.50 or initialScale
            if committed>0 and rectangleCase then return math.abs(p.x)<=targetHalf+0.001 and math.abs(p.z)<=targetHalf+0.001 end
            return p.x >= bounds[1]*scale and p.x <= bounds[2]*scale
                and p.z >= bounds[3]*scale and p.z <= bounds[4]*scale
        end}
    w.crowdsimulation={
        SetVoxelTerrain=function(id) crowdTerrainID=id end,
    }
    w.voxelterrain={GetPrimaryVoxelTerrainEntityID=function() return 1 end,
        GetWorldBounds=function() if widthRun then local h=(widthRun.size or 2048)/2;return V:new(-h,-2304,-h),V:new(h-1,2303,h-1) end;return V:new(-1024,-1280,-1024),V:new(1023,1279,1023) end,
        PointTest=function(_,id,p)
            pointCalls=pointCalls+1
            assert(id==1)
            if groundMode=="pointbad" then return nil end
            if groundMode=="pointempty" and math.abs(p.x-600)>0.001 then return 1 end
            local air=groundMode=="pointreverse" and -1 or 1
            local delta=p.y-heightAt(p.x,p.z)
            return delta==0 and 0 or (delta>0 and air or -air)
        end,
        RayCast=function(_,id,start,direction,depth)
            assert(direction.x==0 and direction.y==-1 and direction.z==0)
            if groundMode=="missing" then return nil end
            if groundMode and groundMode:sub(1,5)=="point" then
                if math.abs(start.x-600)>0.001 or start.z~=0 then return nil end
            end
            if groundMode=="seam" then
                assert(math.abs(math.max(math.abs(start.x),math.abs(start.z))-768)<0.002,
                    "Rectangle grounding crossed the original terrain seam")
            end
            if groundMode=="short" and depth>513 then return nil end
            if groundMode=="short" then
                if groundHeight>start.y or groundHeight<start.y-depth then return nil end
            else
                assert(start.y==rayTop and depth==rayDepth,"Ray used the old vertical range")
            end
            return start.y-heightAt(start.x,start.z)
        end}
    w.boundary={GetBoundaryPartsFromNearRay=function(_,edit)
        assert(math.abs(edit.vRayStart.x-seedPoint[1])<0.001
            and math.abs(edit.vRayStart.z-seedPoint[3])<0.001,"Wrong biome boundary seed")
        queried=queried+1;return true,panels[1],nil end,
        GetMaxPostDistance=function() return 1000 end,
        SetBoundaryEditEnabled=function(_,enabled) editEnabled=enabled end,
        GetAllConnectedBoundaryObjects=function() return selection end,
        CreateNewControlPost=function() return object({}) end,
        CreateNewPanel=function() return object({}) end}
    w.editors={CreateUndoOperationsHierarchy=function()
        edits.posts,edits.panels,edits.addedPosts,edits.addedPanels={},{},{},{}
        return hierarchy
        end,
        CopyToClipboard=function(_,text) clipboardReport=text end}
    if groundMode=="missing" then w.voxelterrain.PointTest=nil end
    local validationCalls,previewCount=0,0
    api={debug={Trace=function(s) trace[#trace+1]=s end},world={GetWorldAPIs=function() return w end},
        undo={IsBusy=function() return false end,IsOperationComplete=function() return true end,
            PreviewChangeList=function() previewCount=previewCount+1;return "busy","preview" end,
            CanCommitPreview=function()
                validationCalls=validationCalls+1
                if controlAccepted and previewCount==2 then return true end
                if pendingKind and validationCalls<=8 then
                    if pendingKind=="nil" then return nil end
                    return false
                end
                if allowCommit then
                    local all={}
                    for _,panel in pairs(edits.panels) do all[#all+1]=panel end
                    for _,panel in ipairs(edits.addedPanels) do all[#all+1]=panel end
                    for _,panel in ipairs(all) do
                        local a,b=panel.data.vBasePosStart,panel.data.vBasePosEnd
                        if math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2)>20.001 then return false end
                    end
                end
                return allowCommit
            end,
            CommitPreview=function() committed=committed+1;return "committed" end,
            CancelPreview=function() cancelled=cancelled+1;return "cancelled" end,
            GetCommitFailReasons=function()
                if controlAccepted and previewCount==2 then return {} end
                if pendingKind and validationCalls<=8 then return {bUnknown=true,outsideBounds=false} end
                return {outsideBounds=not allowCommit,bUnknown=false}
            end,Checkpoint=function() end}}
    io=nil
    loadfile=function(path,...)
        if path:match("Config.ini$") then
            local env=select(2,...)
            return function() env.Factor=widthRun and widthRun.to/1024 or 1.50;env.Mode=mode or "expand";env.Shape=rectangleCase and "rectangle" or "scale" end
        end
        return originalLoadfile(path,...)
    end
    require=function(module)
        if module=="boundarylab.scenery" then return {BeforeLoad=function()end,Advance=function()return false end,Queue=function()end,Shutdown=function()end} end
        if module=="boundarylab.research" then
            return {Progress=function() end,Finish=function() end,AddUIHooks=function() end,Advance=function() end,
                BeforeLoad=function() end,AfterLoad=function() end}
        end
        if module=="Vector3" then return V end
        if module=="Helpers.PopUpDialogUtils" then
            return {RunOKDialog=function(_,message)
                popupCount=popupCount+1
                assert(clipboardReport and clipboardReport:find("Park Expansions 0.57 report",1,true),"Missing clipboard report")
                assert(clipboardReport:find("CONNECTED posts="..#posts.." panels="..#panels,1,true),"Missing contour diagnosis")
                if not allowCommit then assert(message:find("outsideBounds=true",1,true),"Lost rejection details") end
                if controlAccepted then assert(message:find("Unchanged contour: accepted",1,true),"Lost control result") end
                if not allowCommit then
                    assert(clipboardReport:find("TRIAL factor=0.99",1,true),"Missing inward trial")
                    assert(clipboardReport:find("TRIAL factor=1.001",1,true),"Missing tiny outward trial")
                    assert(clipboardReport:find("TRIAL factor=1.01",1,true),"Missing 1% outward trial")
                end
            end}
        end
        return originalRequire(module)
    end
    local database=assert(originalLoadfile(source))()
    local worldClass={OnAdvance=function() end}
    database.AddLuaHooks(function(module,hook) assert(module=="Worlds.CPTWorld");hook(worldClass) end)
    local self={parkExpansionsTerrainSize=widthRun and widthRun.size or 2048,boundaryLabTerrainCreated=parkName~="Saved Park",
        boundaryLabTemplate=template, boundaryLabExpectedBounds=widthRun and bounds or nil,
        boundaryLabActiveSeed=widthRun and seedPoint or nil}
    if widthRun and widthRun.manual then
        local operation
        for i=1,40 do
            local name,value=debug.getupvalue(worldClass.OnAdvance,i)
            if not name then break end
            if name=="expand" then operation=value;break end
        end
        assert(operation,"Could not inspect real boundary operation")
        self.boundaryLabDone=true
        self.boundaryLabTask=coroutine.create(function()operation(self,widthRun.to,true)end)
    end
    for _=1,15000 do worldClass.OnAdvance(self,1/60) end
    clipboardReport=clipboardReport or self.boundaryLabReport
    if widthRun and widthRun.outsideTerrain then
        assert(committed==0 and previewCount==0 and popupCount==1)
        assert(clipboardReport:find("configured size was not clamped or applied",1,true))
    elseif parkName=="Saved Park" then
        assert(committed==0 and queried==0 and popupCount==0 and not editEnabled,"Touched unrelated park")
    elseif mode=="diagnose" then
        assert(committed==0 and queried==1 and popupCount==1 and not editEnabled,"Diagnosis changed geometry")
    elseif alreadyExpanded then
        assert(committed==0 and previewCount==0 and popupCount==1,"Repeated expansion was attempted")
        assert(clipboardReport:find("already expanded contour",1,true),"Missing repeat guard explanation")
    elseif mode=="survey" then
        assert(committed==0 and cancelled==5 and popupCount==1,"Survey committed or did not cancel all previews")
        assert(clipboardReport:find("SURVEY COMPLETE",1,true),"Missing survey summary")
    elseif groundMode=="missing" or groundMode=="pointbad" or groundMode=="pointempty" then
        assert(committed==0 and previewCount==0 and popupCount==1,"Missing ground reached preview or commit")
        assert(clipboardReport:find("GROUND_MISS x=",1,true),"Missing coordinates of the ground failure")
        assert(clipboardReport:find("full_and_short_rays_failed",1,true),"Missing short-ray failure result")
    elseif rectangleCase=="broken" then
        assert(committed==0 and previewCount==0 and popupCount==1,"Invalid ring reached preview")
        assert(clipboardReport:find("simple closed ring",1,true),"Missing topology diagnosis")
    elseif allowCommit then
        assert(committed==1 and cancelled==0 and popupCount==(widthRun and widthRun.manual and 0 or 1),"Expected one successful commit")
        assert(editEnabled,"Did not enable boundary editing")
        assert(plotsUnlocked==true and plotRestrictionsCleared==true and enforcedAreaCleared==true and crowdTerrainID==1,
            "Expansion must unlock plots, clear restrictions, and update crowd terrain")
        for old,new in pairs(edits.posts) do
            if rectangleCase then
                assert(math.abs(math.max(math.abs(new.data.vPos.x),math.abs(new.data.vPos.z))-targetHalf)<0.002)
            else
                assert(math.abs(new.data.vPos.x-old.data.vPos.x*1.50)<1e-5)
                assert(math.abs(new.data.vPos.z-old.data.vPos.z*1.50)<1e-5)
            end
            assert(math.abs(new.data.vPos.y-heightAt(new.data.vPos.x,new.data.vPos.z))<0.001,"Did not ground boundary point")
            assert(math.abs(new.data.nWorldHeight-new.data.vPos.y-0.8)<0.0002,"Lost boundary height above ground")
        end
        local allPanels,incoming,outgoing,nextPost={},{},{},{}
        for _,new in pairs(edits.panels) do allPanels[#allPanels+1]=new end
        for _,new in ipairs(edits.addedPanels) do allPanels[#allPanels+1]=new end
        assert(#edits.addedPosts>0 and #edits.addedPosts==#edits.addedPanels,"Unbalanced boundary subdivision")
        for _,new in ipairs(allPanels) do
            local a,b=new.data.oStartControlPost,new.data.oEndControlPost
            incoming[b]=(incoming[b] or 0)+1
            outgoing[a]=(outgoing[a] or 0)+1
            nextPost[a]=b
            assert(new.data.tSegmentData==nil,"Reused stale geometry")
            assert(new.data.vBasePosStart==new.data.oStartControlPost.data.vPos,"Panel endpoint not grounded")
            assert(math.abs(new.data.nWorldHeightStart-new.data.vBasePosStart.y-0.8)<0.0002,"Panel top not grounded")
            local p,q=new.data.vBasePosStart,new.data.vBasePosEnd
            assert(math.abs(p.y-heightAt(p.x,p.z))<0.001,"Intermediate panel point was not grounded")
            if rectangleCase then assert(math.abs(p.x-q.x)<0.002 or math.abs(p.z-q.z)<0.002,"Corner was cut diagonally") end
            assert(math.sqrt((p.x-q.x)^2+(p.y-q.y)^2+(p.z-q.z)^2)<=18.001,"Oversized panel reached commit")
            assert(new.data.nSmoothness==0,"Stretched inherited curve handles")
        end
        for post,count in pairs(incoming) do assert(count==1 and outgoing[post]==1,"Broken closed contour") end
        for old,new in pairs(edits.panels) do
            assert(new.data.oStartControlPost==edits.posts[old.data.oStartControlPost])
            local cursor=new.data.oEndControlPost
            local steps=0
            while cursor~=edits.posts[old.data.oEndControlPost] do
                cursor=nextPost[cursor];steps=steps+1
                assert(cursor and steps<1000,"Replacement segment did not reconnect to original endpoint")
            end
        end
        for _,post in ipairs(edits.addedPosts) do assert(post.data.nEntityID==nil,"Reused entity ID for added post") end
        for _,panel in ipairs(edits.addedPanels) do assert(panel.data.nEntityID==nil,"Reused entity ID for added panel") end
        local shrinking=widthRun and widthRun.to<widthRun.from
        assert(clipboardReport:find("STRIP_SAMPLES count="..#posts.." before_inside="..(shrinking and #posts or 0).." after_inside="..#posts.." newly_inside="..(shrinking and 0 or #posts),1,true),
            "Missing before/after park territory comparison")
        if groundMode and groundMode:sub(1,5)=="point" then
            assert(pointCalls>0 and clipboardReport:find("GROUND_POINT_RECOVERY x=",1,true),"Native point fallback not exercised")
        end
        if groundMode=="short" then
            assert(clipboardReport:find("GROUND_SHORT_RAY x=",1,true),"Short-ray recovery not recorded")
        end
    else
        assert(committed==0 and cancelled==5 and popupCount==1,"A diagnostic preview was not cancelled")
    end
    io,loadfile,require=originalIO,originalLoadfile,originalRequire
    print("PASS "..name)
end
test("saved park excluded regardless of name","Saved Park",true)
test("diagnose mode does not commit","Any park name",true,"diagnose")
test("scale and endpoint consistency","Any park name",true)
test("rejected preview cancelled","Any park name",false)
test("pending nil then ready","Any park name",true,nil,"nil")
test("unknown flag then ready","Any park name",true,nil,"unknown")
test("unchanged control accepted, expansion rejected","Any park name",false,nil,nil,true)
test("survey cancels even accepted previews","Any park name",true,"survey")
test("saved expanded contour is not expanded again","Any park name",true,nil,nil,nil,true)
test("ground above the old height ceiling is found","Any park name",true,nil,nil,nil,nil,true)

test("tropicalsandbox.bin uses its own contour and arbitrary name","My test",true,nil,nil,nil,nil,nil,"tropicalsandbox.bin")
test("taigasandbox.bin uses its own contour and arbitrary name","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin")
test("mediterraneansandbox.bin uses its own contour and arbitrary name","My test",true,nil,nil,nil,nil,nil,"mediterraneansandbox.bin")

test("long-ray miss recovered at identical X/Z","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin","short")
test("short-ray scan finds ground above the old ceiling","My test",true,nil,nil,nil,nil,true,"taigasandbox.bin","short")
test("actual missing ground prevents preview and reports coordinates","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin","missing")

test("rectangle preserves closure and stays on outer ground","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin","seam","rectangle")
test("concave 190-post ring maps to an exact rectangle","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin","seam","concave190")
test("reversed 190-post ring stays closed","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin","seam","reverse190")
test("broken rectangle source ring prevents preview","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin",nil,"broken")
test("190-post rectangle remains valid across steep hills","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin","seam","hills190")

test("native points recover exact-XZ ground when all rays miss","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin","point","hills190")
test("native point signs are calibrated rather than assumed","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin","pointreverse","hills190")
test("invalid native point results prevent commit","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin","pointbad","rectangle")
test("empty native point column prevents commit","My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin","pointempty","rectangle")

local widths={1152,1344,1536,1792,2040}
for i,width in ipairs(widths) do
 test("research width "..(i==1 and "original" or widths[i-1]).." -> "..width,"My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin",nil,"rectangle",{from=i==1 and 0 or widths[i-1],to=width})
end

test("manual size shrinks known boundary 1792 -> 512", "My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin",nil,"rectangle",{from=1792,to=512,manual=true})
test("manual size 3000 accepted by config path but rejected by actual terrain without clamping", "My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin",nil,"rectangle",{from=1792,to=3000,manual=true,outsideTerrain=true})

local largeWidths={1152,1344,1536,1792,2040,3072,4088}
for i,width in ipairs(largeWidths) do
 test("4K research boundary -> "..width,"My test",true,nil,nil,nil,nil,nil,"taigasandbox.bin",nil,"rectangle",{from=i==1 and 0 or largeWidths[i-1],to=width,size=4096})
end
