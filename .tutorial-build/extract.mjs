import fs from 'node:fs/promises';
const raw=await fs.readFile('D:/openbmc/openbmc-tutorial.md','utf8');
const decode=s=>s.replace(/<\/?(?:span|div|main|a|li|ol|ul|p|strong|em|br|code|pre|table|thead|tbody|tr|td|th)\b[^>]*>/g,'').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&#39;|&apos;/g,"'").replace(/&amp;/g,'&').replace(/&nbsp;/g,' ');
const anchors=[...raw.matchAll(/<a id="([^"]+)"><\/a>/g)];
const topics=anchors.map((m,i)=>{const body=raw.slice(m.index,anchors[i+1]?.index??raw.length);const title=body.match(/^# (.+)$/m)?.[1]??m[1]; const blocks=[...body.matchAll(/```([^\n]*)\n([\s\S]*?)```/g)].map(b=>({lang:b[1].trim(),text:decode(b[2]).trim()}));let safe=body.replace(/```[\s\S]*?```/g,''); const headings=[...safe.matchAll(/^#{2,4} (.+)$/gm)].map(h=>decode(h[1]));return {id:m[1],title,headings,blocks,body:decode(body),line:raw.slice(0,m.index).split('\n').length};});
await fs.writeFile('D:/openbmc/.tutorial-build/source.json',JSON.stringify(topics,null,2));
await fs.writeFile('D:/openbmc/.tutorial-build/source-outline.txt',topics.map(t=>`${t.id}: ${t.title}\n${t.headings.join(' / ')}\nCODE ${t.blocks.filter(b=>!['mermaid',''].includes(b.lang)&&!/[┌┐│]/.test(b.text)).slice(0,4).map(b=>b.text.slice(0,200)).join('\n')}\n`).join('\n'));
console.log(topics.length,topics.map(t=>[t.id,t.blocks.length,t.blocks.filter(b=>/[┌┐│]/.test(b.text)).length]));
