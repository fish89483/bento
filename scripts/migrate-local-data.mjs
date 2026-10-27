import {readFile} from 'node:fs/promises';
import {resolve} from 'node:path';

const envPath=resolve('.env.local');
try{
  const envText=await readFile(envPath,'utf8');
  for(const line of envText.split(/\r?\n/)){
    const match=line.match(/^\s*(VITE_SUPABASE_URL|VITE_SUPABASE_PUBLISHABLE_KEY)\s*=\s*(.*?)\s*$/);
    if(match&&!process.env[match[1]])process.env[match[1]]=match[2].replace(/^['"]|['"]$/g,'');
  }
}catch{}

const url=(process.env.VITE_SUPABASE_URL||'').replace(/\/$/,'');
const key=process.env.VITE_SUPABASE_PUBLISHABLE_KEY||'';
if(!url||!key)throw new Error('請先在 .env.local 設定 Supabase URL 和 publishable key。');

const state=JSON.parse(await readFile(resolve('bento-data.json'),'utf8'));
if(!state?.data?.items||!Array.isArray(state.accounts))throw new Error('bento-data.json 格式不正確。');
const response=await fetch(`${url}/rest/v1/bento_state?on_conflict=id`,{
  method:'POST',
  headers:{apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json',Prefer:'resolution=merge-duplicates,return=minimal'},
  body:JSON.stringify({id:'shared',state})
});
if(!response.ok)throw new Error(`Supabase 匯入失敗（HTTP ${response.status}）：${await response.text()}`);
console.log('已將本機帳號與便當紀錄匯入 Supabase。');
