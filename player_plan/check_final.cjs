const {chromium}=require('/Users/zhengjunfeng/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const fs=require('fs');
const base='/Users/zhengjunfeng/Desktop/temp/player_plan/开发定稿/';
(async()=>{
 const browser=await chromium.launch({headless:true});
 const context=await browser.newContext({viewport:{width:1280,height:900},offline:true,acceptDownloads:true});
 const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('file://'+base+'Mori播放器开发定稿.html');
 if(await page.locator('.task').count()!==83)throw Error('task count');
 await page.screenshot({path:'/Users/zhengjunfeng/Desktop/temp/player_plan/final-plan-desktop.png'});
 await page.locator('.task[data-id=A05] input').check();
 if(!await page.locator('#count').textContent().then(s=>s.startsWith('1 /')))throw Error('task check');
 const dl=page.waitForEvent('download');await page.locator('#export').click();
 const download=await dl;const data=JSON.parse(fs.readFileSync(await download.path(),'utf8'));
 if(!data.tasks.find(t=>t.id==='A05').readerMarked)throw Error('export state');
 for(const width of [1024,390]){await page.setViewportSize({width,height:900});const size=await page.evaluate(()=>[innerWidth,document.documentElement.scrollWidth]);if(size[1]>size[0]+1)throw Error('plan overflow '+size);}
 await page.goto('file://'+base+'UI设计稿.html');
 const f=page.frameLocator('iframe');await f.locator('.m-play svg').waitFor();
 for(const view of ['player','home','library','folders','favorites','search','settings','welcome','import','offline','error']){await f.locator('#m-scene').selectOption(view);}
 await f.locator('#m-scene').selectOption('player');
 await f.getByRole('button',{name:'字幕与音轨',exact:true}).click();await f.getByRole('button',{name:'English',exact:true}).click();
 if(!await f.locator('.m-subtitle').textContent().then(s=>s.includes('journeys')))throw Error('subtitle preview');
 await page.setViewportSize({width:1056,height:850});
 await page.screenshot({path:'/Users/zhengjunfeng/Desktop/temp/player_plan/final-ui-offline.png',fullPage:true});
 if(errors.length)throw Error(JSON.stringify(errors));
 console.log('83 tasks, task export, responsive plan, all UI scenes and offline icons passed.');
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
