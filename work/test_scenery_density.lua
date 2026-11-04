local S=assert(loadfile('work/boundarylab/Main/boundarylab.scenery.lua'))()
local data={groups={{resource='NAT_TestA',instances={}},{resource='NAT_TestB',instances={}}}}
for i=1,18880 do local group=data.groups[i<=10001 and 1 or 2];group.instances[#group.instances+1]={i,20,600,0}end
for _,percent in ipairs({0,1,25,50,75,100})do
 local a=S.SelectEditablePlacements(data,percent)
 local b=S.SelectEditablePlacements(data,percent)
 assert(#a==math.floor(18880*percent/100) and #a==#b)
 for i,row in ipairs(a)do assert(row.row==b[i].row and row.resource==b[i].resource)end
end
local half=S.SelectEditablePlacements(data,50)
assert(#half==9440 and half[1].row[1]==2 and half[#half].row[1]==18880)
assert(#data.groups[1].instances==10001 and #data.groups[2].instances==8879)
print('PASS deterministic density across groups; 18880 to 9440; 0/100%; source data unchanged')
