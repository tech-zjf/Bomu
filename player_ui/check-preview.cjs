const {chromium}=require('/Users/zhengjunfeng/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const fs=require('fs');
(async()=>{
  const browser=await chromium.launch({headless:true});
  const page=await browser.newPage({viewport:{width:1100,height:900},deviceScaleFactor:1});
  const errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.goto('file:///Users/zhengjunfeng/Desktop/temp/player_ui/preview-qa.html');
  const frame=page.frameLocator('iframe');
  await frame.locator('#mori-player-design .m-player').waitFor();
  await page.waitForTimeout(1200);
  const inner=page.frames().find(f=>f!==page.mainFrame());
  async function inspect(name){
    const data=await inner.evaluate(()=>({width:innerWidth,scroll:document.documentElement.scrollWidth,height:document.documentElement.scrollHeight,missingImages:[...document.images].filter(i=>!i.complete||!i.naturalWidth).length,overflow:[...document.querySelectorAll('#mori-player-design *')].filter(e=>e.getBoundingClientRect().right>innerWidth+1&&getComputedStyle(e).display!=='none').slice(0,5).map(e=>e.className)}));
    if(data.scroll>data.width+1||data.missingImages)throw Error(name+JSON.stringify(data));
    console.log(name,JSON.stringify(data));
  }
  await inspect('player');
  await page.screenshot({path:'/Users/zhengjunfeng/Desktop/temp/player_ui/player-desktop.png',fullPage:true});
  await frame.getByRole('button',{name:'字幕与音轨',exact:true}).click();
  await frame.getByRole('button',{name:'English',exact:true}).click();
  if(!await frame.locator('.m-subtitle').textContent().then(x=>x.includes('journeys')))throw Error('subtitle selection');
  await frame.getByRole('button',{name:'播放',exact:true}).click();
  await frame.getByRole('button',{name:'暂停',exact:true}).waitFor();
  await frame.getByRole('button',{name:'前进 10 秒',exact:true}).click();
  if(await frame.locator('#m-time').textContent()!=='08:08')throw Error('seek');
  await frame.getByRole('button',{name:'播放队列',exact:true}).click();
  await inspect('queue');
  await page.screenshot({path:'/Users/zhengjunfeng/Desktop/temp/player_ui/player-queue.png',fullPage:true});
  for(const view of ['home','library','folders','favorites','search','settings','welcome','import','offline','error']){
    await frame.locator('#m-scene').selectOption(view);
    await inspect(view);
    if(['home','library','settings','welcome','import'].includes(view))await page.screenshot({path:'/Users/zhengjunfeng/Desktop/temp/player_ui/'+view+'-desktop.png',fullPage:true});
  }
  await frame.locator('#m-scene').selectOption('library');
  await frame.getByRole('button',{name:'自然',exact:true}).click();
  if(await frame.locator('#m-library-results .m-media-card').count()!==1)throw Error('category filter');
  await frame.getByRole('button',{name:'列表视图',exact:true}).click();
  if(await frame.locator('#m-library-results .m-list-row').count()!==1)throw Error('list view');
  await frame.locator('#m-scene').selectOption('search');
  await frame.locator('#m-search').fill('不存在的影片');
  await frame.getByRole('heading',{name:'没有找到这段影像'}).waitFor();
  await frame.locator('#m-scene').selectOption('import');
  await frame.getByRole('button',{name:'添加到视频库',exact:true}).click();
  await frame.getByRole('button',{name:'查看',exact:true}).waitFor();
  console.log('Import flow complete');
  for(const width of [768,390,320]){
    await page.setViewportSize({width,height:900});
    for(const view of ['player','home','library','settings','welcome','import','offline','error']){
      await frame.locator('#m-scene').selectOption(view);
      await page.waitForTimeout(40);
      await inspect(width+' '+view);
    }
    if(width===320){await frame.locator('#m-scene').selectOption('player');await page.screenshot({path:'/Users/zhengjunfeng/Desktop/temp/player_ui/player-mobile.png',fullPage:true});}
  }
  console.log('JS errors:',JSON.stringify(errors));
  if(errors.length)throw Error('runtime errors');
  await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
