const fs=require('fs'),vm=require('vm'),assert=require('assert');
const listeners={},calls=[],roots=[];
function element(){return{children:[],style:{},attributes:{},appendChild(x){this.children.push(x)},setAttribute(k,v){this.attributes[k]=v}}}
let code=fs.readFileSync('work/boundarylab/UI/loading.js','utf8').replace(/^import .*;\r?\n/gm,'').replace(/^export /gm,'');
code+='\nglobalThis.receive=receiveProgress;';
const context={console,loadCSS(){},Engine:{whenReady:{then(fn){fn()}},addListener(n,fn){listeners[n]=fn},sendEvent(...args){calls.push(args)}},document:{body:{appendChild(x){roots.push(x)}},createElement:element}};
vm.runInNewContext(code,context);assert.equal(roots.length,0);
const receive=(...args)=>context.receive(JSON.stringify(args));
receive(true,25,'Preparing terrain…');assert.equal(roots.length,1);const root=roots[0];
assert.equal(root.attributes['aria-valuenow'],'25');assert.equal(root.style.display,'block');
receive(true,45,'Converting existing park…');assert.equal(roots.length,1);assert.equal(root.children[1].children[0].textContent,'Converting existing park…');
context.receive('not JSON');receive(true,'bad','test');assert.equal(root.attributes['aria-valuenow'],'45');
receive(true,150,'Ready');assert.equal(root.attributes['aria-valuenow'],'100');
listeners.Hide();assert.equal(root.style.display,'none');receive(true,90,'Late event');assert.equal(root.style.display,'none');
listeners.Show();assert.equal(root.style.display,'none');receive(true,5,'Next park');assert.equal(root.style.display,'block');assert.equal(root.attributes['aria-valuenow'],'5');
receive(false,100,'Done');assert.equal(root.style.display,'none');
assert(calls.every(c=>c[0]==='ParkExpansions_RequestLoadProgress' && c.length===1));
console.log('PASS loading progress, invalid payloads, completion, Hide/Show reset and late-event isolation');
