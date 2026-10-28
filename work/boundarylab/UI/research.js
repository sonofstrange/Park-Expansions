import * as Engine from '/js/common/core/Engine.js';
import * as preact from '/js/common/lib/preact.js';
import { loadCSS } from '/js/common/util/CSSUtil.js';
import { ScrollPane } from '/js/common/components/ScrollPane.js';
import { Icon } from '/js/common/components/Icon.js';
import { Button } from '/js/project/components/Button.js';
import { HighlightTab } from '/js/project/components/HighlightTab.js';
import { ResearchModule } from '/js/project/modules/research/ResearchModule.js';
loadCSS('boundarylab/Research');

export let WIDTHS = [1152, 1344, 1536, 1792, 2040];
export const HEIGHTS = [400, 700, 1000, 1500, 2048];
export let WIDTH_COSTS = [12500, 25000, 50000, 100000, 200000];
export const HEIGHT_COSTS = [12500, 25000, 50000, 100000, 200000];
export const COSTS = WIDTH_COSTS;
let snapshot = {managed:false, width:0, height:0, points:0, busy:false, progress:0,
    message:'Connecting to park…', free:false, researchEnabled:true, manualSize:2040, manualHeight:2048};
const panels = new Set();
const literal = text => `[STRING_LITERAL:Value=|${text}|]`;

const pointsText = value => String(Math.floor(value)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
const ROMAN = ['I','II','III','IV','V','VI','VII'];
const branchTitle = name => name==='width' ? 'Park Size' : 'Height';
const dimension = (name,value) => name==='width' ? value+' × '+value+' m' : 'Y='+value+' m';

class ExpansionPanel extends preact.Component {
    state = {branch:'width', level:null};
    componentDidMount() { panels.add(this); Engine.sendEvent('BoundaryLab_RequestState'); }
    componentWillUnmount() { panels.delete(this); }
    selected() {
        const branch=this.state.branch;
        const maxLevel=branch==='width' ? WIDTHS.length : 5;
        return {branch, level:this.state.level || Math.min(snapshot[branch]+1,maxLevel)};
    }
    upgrade(name,level) {
        const unlocked=snapshot[name], index=level-1;
        const purchased=level<=unlocked, next=level===unlocked+1;
        const restore=level===unlocked && unlocked>0;
        const costs=name==='width' ? WIDTH_COSTS : HEIGHT_COSTS;
        const cost=costs[index] || 0;
        const allowed=snapshot.researchEnabled && snapshot.managed && !snapshot.busy
            && (next || restore) && (restore || snapshot.free || snapshot.points>=cost);
        let label,reason,status;
        if (!snapshot.managed) {
            label='Unavailable for this park';reason='';status='Unavailable';
        } else if (snapshot.busy) {
            label='Applying…';reason='';status='Applying';
        } else if (restore) {
            label=name==='width' ? 'Apply Boundary' : 'Apply Height';
            reason='No research points required.';status='Researched';
        } else if (purchased) {
            label='Researched';reason='';status='Researched';
        } else if (!next) {
            label='Previous upgrade required';
            reason='Requires '+branchTitle(name)+' '+ROMAN[index-1]+'.';status='Locked';
        } else if (snapshot.free) {
            label='Unlock for free';reason='Research disabled in sandbox settings.';status='Available';
        } else {
            label='Research · '+pointsText(cost)+' points';
            reason=allowed ? '' : 'Requires '+pointsText(cost-snapshot.points)+' more points.';
            status=allowed ? 'Available' : 'Not enough points';
        }
        return {name,level,index,purchased,next,restore,allowed,label,reason,status,
            value:(name==='width' ? WIDTHS : HEIGHTS)[index]};
    }
    branch(name) {
        const selected=this.selected(),unlocked=snapshot[name];
        const maxLevel=name==='width' ? WIDTHS.length : 5;
        const costs=name==='width' ? WIDTH_COSTS : HEIGHT_COSTS;
        return preact.h('div',{className:'BL_branch'},
            preact.h('div',{className:'BL_branchHeading'},
                preact.h('div',{className:'BL_branchTitle'},branchTitle(name)),
                preact.h('div',{className:'BL_branchCount'},unlocked+' / '+maxLevel+' researched')),
            (name==='width' ? WIDTHS : HEIGHTS).map((value,index)=>{
                const level=index+1,u=this.upgrade(name,level);
                const active=selected.branch===name && selected.level===level;
                const classes='BL_node'+(u.purchased?' purchased':'')+(u.next?' available':'')
                    +(active?' selected':'')+(!u.purchased && !u.next?' locked':'');
                return preact.h('div',{className:'BL_stage',key:level},
                    index>0 && preact.h('div',{className:'BL_link'+(level<=unlocked?' complete':'')}),
                    preact.h(Button,{rootClassName:classes,
                        label:literal(dimension(name,value)),
                        subLabel:literal(branchTitle(name)+' '+ROMAN[index]+' · '+
                            (u.purchased?'Researched':snapshot.free?'Free':pointsText(costs[index])+' points')),
                        icon:u.purchased?'/img/icons/tick.svg':'/img/icons/researchPoints.svg',
                        modifiers:'inverted',disabled:snapshot.busy,
                        onSelect:()=>this.setState({branch:name,level})}));
            }));
    }
    purchase(u) {
        // Selecting a node only opens its details. Only this action spends points.
        if (this.upgrade(u.name,u.level).allowed)
            Engine.sendEvent('BoundaryLab_Purchase',u.name,u.level);
    }
    details() {
        const selection=this.selected(),u=this.upgrade(selection.branch,selection.level);
        const current=snapshot[u.name];
        const currentValue=u.name==='width'
            ? (current ? dimension('width',WIDTHS[current-1]) : 'Original boundary')
            : dimension('height',current ? HEIGHTS[current-1] : 255);
        return preact.h('div',{className:'BL_details'},
            preact.h('div',{className:'BL_points'},
                preact.h('span',null,'Research Points'),
                preact.h('div',{className:'BL_balance'},
                    preact.h(Icon,{rootClassName:'BL_pointsIcon',src:'/img/icons/researchPoints.svg'}),
                    preact.h('span',null,pointsText(snapshot.points)))),
            preact.h('div',{className:'BL_info'},
                preact.h('div',{className:'BL_infoHeader'},
                    preact.h('h2',null,branchTitle(u.name)+' '+ROMAN[u.index]),
                    preact.h('div',{className:'BL_badge'+(u.purchased?' complete':'')},u.status)),
                preact.h('div',{className:'BL_infoBody'},
                    preact.h('div',{className:'BL_preview '+(u.name==='width'?'area':'height')},
                        preact.h('div',{className:'BL_previewLabel'},u.name==='width'?'Buildable area':'Height limit'),
                        preact.h('div',{className:'BL_previewValue'},dimension(u.name,u.value))),
                    preact.h('div',{className:'BL_limitRow'},
                        preact.h('span',null,'Current limit'),preact.h('strong',null,currentValue)),
                    preact.h('div',{className:'BL_limitRow target'},
                        preact.h('span',null,'Upgrade limit'),preact.h('strong',null,dimension(u.name,u.value))),
                    u.reason && preact.h('div',{className:'BL_requirement'},u.reason),
                    preact.h(Button,{rootClassName:'BL_researchAction',label:literal(u.label),
                        modifiers:'inverted',disabled:!u.allowed,onSelect:()=>this.purchase(u)}),
                    preact.h('p',{className:'BL_detailNote'},u.name==='height'
                        ? 'Measured from world Y=0.' : 'Expanding the park resets undo history.'))));
    }
    manual() {
        return preact.h('div',{className:'BL_manual'},
            preact.h('h2',null,'Manual configuration'),
            preact.h('p',null,'Research disabled.'),
            preact.h('div',{className:'BL_manualLimits'},
                preact.h('div',{className:'BL_manualMetric'},preact.h('span',null,'PARK SIZE'),
                    preact.h('strong',null,dimension('width',snapshot.manualSize))),
                preact.h('div',{className:'BL_manualMetric'},preact.h('span',null,'HEIGHT CEILING'),
                    preact.h('strong',null,dimension('height',snapshot.manualHeight)))),
            preact.h('p',null,'Change limits in Config.ini, then reload the park. Changing park size resets undo history.'),
            (snapshot.manualSize>2048 || snapshot.manualHeight>2048) && preact.h('div',{className:'BL_warning'},
                'Values above 2048 may be unstable.'));
    }
    render(props = this.props || {}, state, context = {}) {
        // ViewStack.ShowHide delegates visibility to each child.
        if (props.hidden || context.visible === false) return null;
        return preact.h('div',{className:'BL_panel'},
            preact.h('div',{className:'BL_header'},
                preact.h('h1',null,'Park Expansions'),
                preact.h(Button,{rootClassName:'BL_report',label:literal('Copy Report'),modifiers:'inverted',
                    onSelect:()=>Engine.sendEvent('BoundaryLab_Report')})),
            preact.h('div',{className:'BL_status'+(snapshot.message==='Park conversion successful.'?' success':''),role:'status'},snapshot.message),
            !snapshot.managed && preact.h('div',{className:'BL_unavailable'},
                'Supported existing local Sandbox and Challenge parks are converted automatically during loading.'),
            snapshot.researchEnabled ? preact.h('div',{className:'BL_workspace'},
                preact.h('div',{className:'BL_tree'},
                    preact.h('div',{className:'BL_treeHeader'},
                        preact.h('span',null,'Research'),
                        snapshot.free && preact.h('span',{className:'BL_treeHint'},'Free research')),
                    preact.h(ScrollPane,{rootClassName:'BL_treeScroll',contentClassName:'BL_treeContent'},
                        preact.h('div',{className:'BL_columns'},this.branch('width'),this.branch('height')))),
                this.details()) : this.manual());
    }
}

// Add one tab to the actual Research navigator. Keep existing trees and their
// render logic intact, and do not insert purchasing controls into the front end.
if (!ResearchModule.prototype.boundaryLabInstalled) {
    const original=ResearchModule.prototype.render;
    ResearchModule.prototype.render=function(props,state) {
        const root=original.call(this,props,state);
        if (props.isFrontEnd) return root;
        const nav=root?.children?.find(child => child?.attributes?.rootClassName==='Research_container');
        if (!nav || !Array.isArray(nav.attributes.tabs)) return root;
        const index=nav.attributes.tabs.length;
        nav.attributes={...nav.attributes, tabs:[...nav.attributes.tabs,
            preact.h(HighlightTab,{label:literal('Park Expansions'),modifiers:'alt inverted'})]};
        nav.children=[...nav.children,preact.h(ExpansionPanel,{key:'BoundaryLab'})];
        if (state.tabIndex===index) nav.attributes.visibleIndex=index;
        return root;
    };
    ResearchModule.prototype.boundaryLabInstalled=true;
}

let overlay, overlayFill, overlayText;
function updateOverlay() {
    if (!overlay && snapshot.busy) {
        overlay=document.createElement('div'); overlay.className='BL_progress';
        overlay.setAttribute('role','progressbar'); overlay.setAttribute('aria-label','Park Expansions');
        overlay.setAttribute('aria-valuemin','0'); overlay.setAttribute('aria-valuemax','100');
        overlayText=document.createElement('div'); overlayText.className='BL_progressText';
        const track=document.createElement('div'); track.className='BL_progressTrack';
        overlayFill=document.createElement('div'); overlayFill.className='BL_progressFill';
        track.appendChild(overlayFill);overlay.appendChild(overlayText);overlay.appendChild(track);
        document.body.appendChild(overlay);
    }
    if (overlay) {
        overlay.style.display=snapshot.busy?'block':'none';
        const percent=Math.max(0,Math.min(100,Math.floor(snapshot.progress)));
        overlayFill.style.width=percent+'%';
        overlayText.textContent=`${snapshot.message}  ${percent}%`;
        overlay.setAttribute('aria-valuenow',String(percent));
    }
}
export function receiveState(payload) {
    let values;
    try { values=JSON.parse(payload); } catch (error) { console.error('BoundaryLab: invalid state',error);return; }
    if (!Array.isArray(values) || (values.length!==8 && values.length!==11 && values.length!==12)) return;
    const [managed,width,height,points,busy,progress,message,free]=values;
    if (typeof managed!=='boolean' || typeof busy!=='boolean' || typeof free!=='boolean'
        || typeof message!=='string' || ![width,height,points,progress].every(Number.isFinite)) return;
    const researchEnabled=values.length===8 ? true : values[8];
    const manualSize=values.length===8 ? 2040 : values[9];
    const manualHeight=values.length===8 ? 2048 : values[10];
    if (typeof researchEnabled!=='boolean' || ![manualSize,manualHeight].every(Number.isFinite)) return;
    const terrainSize=values.length===12 ? values[11] : 2048;
    if (terrainSize!==2048 && terrainSize!==4096) return;
    if (terrainSize===4096) {
        WIDTHS=[1152, 1344, 1536, 1792, 2040, 3072, 4088];
        WIDTH_COSTS=[12500, 25000, 50000, 100000, 200000, 400000, 800000];
    } else {
        WIDTHS=[1152, 1344, 1536, 1792, 2040];
        WIDTH_COSTS=[12500, 25000, 50000, 100000, 200000];
    }
    snapshot={managed,width,height,points,busy,progress,message,free,researchEnabled,manualSize,manualHeight,terrainSize};
    panels.forEach(panel=>panel.enqueueForceUpdate());
    updateOverlay();
}
Engine.whenReady.then(()=>{
    Engine.addListener('BoundaryLab_State',receiveState);
    Engine.sendEvent('BoundaryLab_RequestState');
});
