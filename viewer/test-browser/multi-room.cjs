const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const path = require('node:path');

(async () => {
  const viewer = path.resolve(__dirname, '..');
  const port = Number(process.env.HOME_LISTEN_BROWSER_PORT || 4175);
  const base = 'http://127.0.0.1:' + port;
  const server = spawn(process.execPath, [path.join(viewer, 'node_modules/vite/bin/vite.js'), '--host', '127.0.0.1', '--port', String(port), '--strictPort'], { cwd: viewer, stdio: 'ignore' });
  let serverError; server.on('error', error => { serverError = error; });
  let browser;
  try {
    const deadline = Date.now() + 20000;
    while (true) {
      if (serverError) throw serverError;
      try { if ((await fetch(base)).ok) break; } catch {}
      if (Date.now() >= deadline) throw new Error('Local browser test server did not start');
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 1100, height: 900 } });
    const page = await context.newPage();
    const errors = [], requests = [], leaves = [];
    page.on('pageerror', e => errors.push(String(e)));
    await context.route('**/*', route => {
      const url = new URL(route.request().url());
      if (url.hostname !== '127.0.0.1' && !['blob:', 'data:'].includes(url.protocol)) return route.abort();
      return route.fallback();
    });
    const app = `export function initializeApp(config){return {config}};`;
    const auth = `const auth={currentUser:{uid:'away',getIdToken:async()=> 'test-token'},authStateReady:async()=>{}}; export function getAuth(){return auth} export async function signInAnonymously(){return {user:auth.currentUser}} export async function signOut(){window.__signOuts++;auth.currentUser=null}`;
    const firestore = `
      export function getFirestore(){return {database:true}}
      function path(args){const first=args.shift();return (first.path?first.path+'/':'')+args.join('/')}
      export function doc(...args){return {path:path(args)}}
      export function collection(...args){return {path:path(args)}}
      export function onSnapshot(ref,...args){const next=typeof args[0]==='function'?args[0]:args[1];let active=true;
        setTimeout(()=>{if(!active)return;let data=ref.path.split('/').length===2?window.__rooms[ref.path.split('/')[1]]:{answer:'test-answer',ended:false};
          next({metadata:{fromCache:false},exists:()=>Boolean(data),data:()=>data,docChanges:()=>[]})},10);return()=>{active=false}}
      export async function updateDoc(){} export async function addDoc(){return {id:'candidate'}}
      export const Timestamp={fromDate:d=>d};`;
    await context.route(/\/node_modules\/\.vite\/deps\/firebase_app\.js/, r => r.fulfill({ contentType: 'text/javascript', body: app }));
    await context.route(/\/node_modules\/\.vite\/deps\/firebase_auth\.js/, r => r.fulfill({ contentType: 'text/javascript', body: auth }));
    await context.route(/\/node_modules\/\.vite\/deps\/firebase_firestore\.js/, r => r.fulfill({ contentType: 'text/javascript', body: firestore }));
    let serial = 0;
    await context.route('**/api/**', async route => {
      const request = route.request(), path = new URL(request.url()).pathname;
      requests.push({ path, method: request.method() });
      let body = {};
      if (path === '/api/config') body = { firebase: { projectId: 'demo-homelisten', appId: 'test', apiKey: 'public-test' }, vapidPublicKey: '' };
      else if (path.endsWith('/sessions')) body = { sessionId: `session_${++serial}`, expiresAt: new Date(Date.now()+7200000).toISOString() };
      else if (path.endsWith('/ice')) body = { iceServers: [] };
      else if (path.endsWith('/leave')) { leaves.push(path.split('/')[3]); body = { left: true }; }
      else if (path.includes('/device')) body = { registered: true };
      else body = { roomId: path.split('/')[3], room: {} };
      await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
    });
    await context.addInitScript(() => {
      const rooms = [{ id:'room_a',name:'Bedroom',listen:true,alerts:true },{ id:'room_b',name:'Children room',listen:true,alerts:true }];
      if (!localStorage.getItem('qa-seeded')) {
        localStorage.setItem('homelisten-rooms-v1',JSON.stringify({version:1,selected:'room_a',rooms,pendingLeaves:[]})); localStorage.setItem('qa-seeded','true');
      }
      window.__rooms=Object.fromEntries(rooms.map(r=>[r.id,{roomName:r.name,ownerUid:'home_'+r.id,members:{away:true,other:true},memberAccess:{},watchers:{away:true},sharing:true,audioAvailable:true,lastSeenMs:Date.now()}]));
      window.__pcs=[]; window.__signOuts=0;window.__unsubscribes=0;
      window.__readClips=()=>new Promise((resolve,reject)=>{const q=indexedDB.open('home-listen-recordings',1);q.onupgradeneeded=()=>q.result.createObjectStore('clips',{keyPath:'id'});q.onerror=()=>reject(q.error);q.onsuccess=()=>{const db=q.result,r=db.transaction('clips').objectStore('clips').getAll();r.onsuccess=()=>{resolve(r.result.map(c=>({roomId:c.roomId,roomName:c.roomName,name:c.name,durationMs:c.durationMs})));db.close()}}});
      HTMLMediaElement.prototype.play=function(){this.__played=true;return Promise.resolve()};
      HTMLMediaElement.prototype.pause=function(){this.__paused=true};
      const subscription={toJSON:()=>({endpoint:'https://fcm.googleapis.com/test',keys:{}}),unsubscribe:async()=>{window.__unsubscribes++;return true}};
      const registration={pushManager:{getSubscription:async()=>subscription,subscribe:async()=>subscription}};
      Object.defineProperty(navigator,'serviceWorker',{value:{register:async()=>registration,ready:Promise.resolve(registration),addEventListener:(type,fn)=>{window.__swMessage=fn}}});
      window.PushManager=class{};
      class FakePeer{
        constructor(config){this.config=config;this.connectionState='new';this.channels=[];this.closed=false;window.__pcs.push(this)}
        createDataChannel(){const channel={readyState:'open',send(message){if(message==='subscribe')queueMicrotask(()=>this.onmessage?.({data:JSON.stringify({type:'recording-ready',version:1})}))},close(){this.readyState='closed';this.onclose?.()}};this.channels.push(channel);return channel}
        addTransceiver(){} async createOffer(){return {type:'offer',sdp:'test-offer'}} async setLocalDescription(value){this.localDescription=value}
        async setRemoteDescription(value){this.remoteDescription=value;this.connectionState='connected';this.onconnectionstatechange?.();this.ontrack?.({streams:[new MediaStream()]})}
        async addIceCandidate(){} getConfiguration(){return this.config}setConfiguration(v){this.config=v}
        close(){this.closed=true;this.connectionState='closed'}
      }
      window.RTCPeerConnection=FakePeer;
    });
    try {
      await page.goto(base);
      await page.waitForFunction(()=>document.querySelector('#room-connections')?.textContent.includes('Bedroom · Connected')&&document.querySelector('#room-connections')?.textContent.includes('Children room · Connected'),null,{timeout:20000});
      assert.equal(await page.locator('#room-select option').count(),2);
      assert.equal(await page.evaluate(()=>window.__pcs.length),2);
      await page.selectOption('#room-select','room_b');
      assert.equal(await page.evaluate(()=>window.__pcs.some(p=>p.closed)),false);
      assert.equal(await page.evaluate(()=>[...document.querySelectorAll('audio')].filter(a=>a.srcObject&&!a.muted).length),1);
      await page.click('#record-device-button');
      await page.evaluate(()=>{const channel=window.__pcs[1].channels[0];for(let i=0;i<20;i++){const bytes=new ArrayBuffer(3212),v=new DataView(bytes);v.setUint32(0,0x484c4131);v.setUint32(4,i,true);v.setUint32(8,i*100,true);channel.onmessage?.({data:bytes})}});
      await page.selectOption('#room-select','room_a');
      await page.waitForFunction(async()=>{const clips=await window.__readClips();return clips.length===1&&clips[0].roomId==='room_b'});
      const clips=await page.evaluate(()=>window.__readClips());
      assert.equal(clips[0].durationMs,2000);assert.equal(clips[0].roomName,'Children room');
      assert.equal(await page.evaluate(()=>window.__pcs.some(p=>p.closed)),false);
      await page.click('#alerts-button');
      assert.equal(await page.evaluate(()=>window.__unsubscribes),0);
      await page.click('#logout-button');
      await page.waitForFunction(()=>document.querySelector('#room-select')?.value==='room_b');
      assert.deepEqual(leaves,['room_a']);
      const state=await page.evaluate(()=>({closed:window.__pcs.map(p=>p.closed),signOuts:window.__signOuts,registry:JSON.parse(localStorage.getItem('homelisten-rooms-v1'))}));
      assert.deepEqual(state.closed,[true,false]);assert.equal(state.signOuts,0);assert.deepEqual(state.registry.rooms.map(r=>r.id),['room_b']);
      await page.selectOption('#room-select','room_b');
      await page.waitForFunction(()=>document.querySelector('.recording-list')?.textContent.includes('Children_room'));
      await page.setViewportSize({width:390,height:844});
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
      assert.deepEqual(errors,[]);
      console.log(JSON.stringify({passed:true,checks:['two concurrent peers','one audible room','switch preserves peers','manual room-tagged 2s WAV','switch saves recording','shared push retained','logout scoped to one room/device','saved room retained','mobile no horizontal overflow'],sessions:serial,leaves,clips,errors},null,2));
    } catch(error) {
      console.log(JSON.stringify({error:String(error),errors,requests,pageText:await page.locator('body').innerText().catch(()=>null)},null,2));
      throw error;
    }
  } finally {await browser?.close(); server.kill()}
})().catch(e=>{console.error(e);process.exitCode=1});
