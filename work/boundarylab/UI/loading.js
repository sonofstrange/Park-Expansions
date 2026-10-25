import * as Engine from '/js/common/core/Engine.js';
import { loadCSS } from '/js/common/util/CSSUtil.js';
loadCSS('boundarylab/Loading');

let root, fill, label, value;
let visible=true;
let state={active:false,percent:0,message:''};
function render() {
    if (!root && state.active && visible) {
        root=document.createElement('div');root.className='PE_loading';
        root.setAttribute('role','progressbar');root.setAttribute('aria-label','Park Expansions');
        root.setAttribute('aria-valuemin','0');root.setAttribute('aria-valuemax','100');
        const title=document.createElement('div');title.className='PE_loadingTitle';title.textContent='Park Expansions';
        const row=document.createElement('div');row.className='PE_loadingRow';
        label=document.createElement('div');label.className='PE_loadingLabel';
        value=document.createElement('div');value.className='PE_loadingValue';
        row.appendChild(label);row.appendChild(value);
        const track=document.createElement('div');track.className='PE_loadingTrack';
        fill=document.createElement('div');fill.className='PE_loadingFill';
        track.appendChild(fill);root.appendChild(title);root.appendChild(row);root.appendChild(track);
        document.body.appendChild(root);
    }
    if (!root) return;
    root.style.display=state.active && visible ? 'block':'none';
    fill.style.width=state.percent+'%';value.textContent=state.percent+'%';label.textContent=state.message;
    root.setAttribute('aria-valuenow',String(state.percent));
    root.setAttribute('aria-valuetext',state.message+' '+state.percent+'%');
}
export function receiveProgress(payload) {
    let values;
    try {values=JSON.parse(payload);} catch (_) {return;}
    if (!Array.isArray(values) || values.length!==3) return;
    const [active,percent,message]=values;
    if (typeof active!=='boolean' || !Number.isFinite(percent) || typeof message!=='string') return;
    state={active,percent:Math.max(0,Math.min(100,Math.floor(percent))),message};
    render();
}
function show() {
    visible=true;state={active:false,percent:0,message:''};render();
    Engine.sendEvent('ParkExpansions_RequestLoadProgress');
}
function hide() {visible=false;state={active:false,percent:0,message:''};render();}
Engine.whenReady.then(()=>{
    Engine.addListener('ParkExpansions_LoadProgress',receiveProgress);
    Engine.addListener('Show',show);
    Engine.addListener('Hide',hide);
    Engine.sendEvent('ParkExpansions_RequestLoadProgress');
});
