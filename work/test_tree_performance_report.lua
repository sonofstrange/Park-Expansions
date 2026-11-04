local nativeRequire=require
local pathReads,findReads=0,0
api={entity={NullEntityID=0,GetEntityPath=function(id)pathReads=pathReads+1;return '/Park/Tree'..id end,
 FindEntityByName=function(path)findReads=findReads+1;local id=tonumber(path:match('Tree(%d+)/AudioTree$'));return id==2 and 0 or id+100 end},
 transform={GetParent=function(id)return id==103 and 999 or id-100 end}}
local ids={1,2,3,4}
local w={scenery={GetAllSceneryIDs=function()return ids end,
 GetPropResourceName=function(_,id)return id<4 and 'NAT_Tree_Test' or 'NAT_Bush_Test' end}}
local R=assert(loadfile('work/boundarylab/Main/boundarylab.research.lua'))()
local report=R.SceneryPerformanceReport(w)
assert(report:find('TREES_SAMPLED=3',1,true))
assert(report:find('DIRECT_AUDIO_CHILDREN=1',1,true))
assert(report:find('NO_DIRECT_AUDIO_MATCH=2',1,true))
assert(pathReads==3 and findReads==3)
ids={};for i=1,18880 do ids[i]=i end
w.scenery.GetPropResourceName=function()return 'PE_NAT_Tree_Test' end
pathReads=0;findReads=0
R.SceneryPerformanceReport(w)
assert(pathReads<=256 and findReads<=256,'Unbounded audit')
api.entity.FindEntityByName=function()error('Unsupported path query')end
report=R.SceneryPerformanceReport(w)
assert(report:find('TREE_AUDIT_QUERY_ERRORS=256',1,true))
api.entity.GetEntityPath=nil
pathReads=0;report=R.SceneryPerformanceReport(w)
assert(report:find('AUDIO_QUERY_AVAILABLE=false',1,true) and pathReads==0)
assert(R.SceneryPerformanceReport({})=='TREE_AUDIT=unavailable')
require=nativeRequire
print('PASS bounded read-only tree/audio audit; ownership check; absent APIs and lookup errors')
