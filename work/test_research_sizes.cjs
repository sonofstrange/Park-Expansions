const fs=require('fs'),vm=require('vm'),assert=require('assert');
const source=fs.readFileSync('work/boundarylab/UI/research.js','utf8')
 .replace(/^import .*;\r?\n/gm,'').replace(/export (const|let|function) /g,'$1 ');
const context={Engine:{whenReady:{then(){}}},preact:{Component:class{}},loadCSS(){},ResearchModule:class{},console};
vm.createContext(context);
vm.runInContext(source+'\nglobalThis.testAPI={receiveState,getWidths:()=>WIDTHS};',context);
const base=[true,0,0,1000,false,0,'Ready',false,true,2040,2048];
context.testAPI.receiveState(JSON.stringify([...base,4096]));
assert.deepStrictEqual(Array.from(context.testAPI.getWidths()),[1536,2040,2560,3072,4088]);
context.testAPI.receiveState(JSON.stringify([...base,2048]));
assert.deepStrictEqual(Array.from(context.testAPI.getWidths()),[1152,1344,1536,1792,2040]);
context.testAPI.receiveState(JSON.stringify(base));
assert.equal(context.testAPI.getWidths()[4],2040);
console.log('PASS research cards follow actual 2K/4K terrain and accept the legacy state payload');
