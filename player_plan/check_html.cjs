const {chromium}=require('/Users/zhengjunfeng/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
(async()=>{
 const browser=await chromium.launch({headless:true});
 const page=await browser.newPage({viewport:{width:1440,height:1000},acceptDownloads:true});
 await page.goto('file:///Users/zhengjunfeng/Desktop/temp/player_plan/交付文件/Mac播放器_完整方案.html');
 await page.screenshot({path:'/Users/zhengjunfeng/Desktop/temp/player_plan/html-preview.png'});
 const info=await page.evaluate(()=>({title:document.title,tasks:document.querySelectorAll('.task').length,sources:document.querySelectorAll('.source').length,chapters:document.querySelectorAll('main section').length,overflow:document.documentElement.scrollWidth>innerWidth}));
 await page.locator('.task input').first().check();
 info.mark=await page.locator('#progress').innerText();
 await page.reload();
 info.persisted=await page.locator('.task input').first().isChecked();
 await page.locator('.task input').first().uncheck();
 await page.setViewportSize({width:960,height:900});
 info.narrowOverflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth);
 console.log(JSON.stringify(info));
 if(info.tasks!==79 || info.sources!==32 || info.overflow || info.narrowOverflow || !info.persisted) throw Error('HTML validation failed');
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
