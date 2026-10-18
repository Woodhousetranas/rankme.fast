// Maintenance-only proofs. Never import the application or provider adapters.
export function canonical(value:unknown):string {
 if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';
 if(value&&typeof value==='object')return '{'+Object.entries(value).sort(([a],[b])=>a.localeCompare(b)).map(([key,item])=>JSON.stringify(key)+':'+canonical(item)).join(',')+'}';
 return JSON.stringify(value);
}
export type RedisProof={at:number;entries:Record<string,{expires:number;type:string;value:unknown}>};
export function remainingRedis(proof:RedisProof,at:number){
 if(!Number.isSafeInteger(proof.at)||!Number.isSafeInteger(at)||at<proof.at||!proof.entries||Array.isArray(proof.entries))throw Error('Invalid Redis recovery clock');
 return Object.fromEntries(Object.entries(proof.entries).filter(([,entry])=>entry.expires===-1||entry.expires>at));
}
export function redisMatches(before:RedisProof,after:RedisProof){return canonical(remainingRedis(before,after.at))===canonical(remainingRedis(after,after.at));}

// One atomic read. Hex-encode bulk bytes so binary values cannot be changed by
// JSON/UTF-8 decoding. Sort unordered hashes/sets; preserve list/stream order.
export const REDIS_PROOF=String.raw`
local keys=redis.call('KEYS','*')
if #keys>10000 then return redis.error_reply('Recovery proof key limit exceeded') end
table.sort(keys)
local function hex(v) return (v:gsub('.',function(c) return string.format('%02x',string.byte(c)) end)) end
local function bytes(v)
 if type(v)=='string' then return hex(v) end
 if type(v)=='table' then local out={}; for i,x in ipairs(v) do out[i]=bytes(x) end; return out end
 return v
end
local t=redis.call('TIME');local now=tonumber(t[1])*1000+math.floor(tonumber(t[2])/1000)
local entries={}
for _,key in ipairs(keys) do
 local kind=redis.call('TYPE',key).ok
 local value
 if kind=='string' then value=redis.call('GET',key)
 elseif kind=='hash' then
  local raw=redis.call('HGETALL',key);local pairs={}
  for i=1,#raw,2 do pairs[#pairs+1]={raw[i],raw[i+1]} end
  table.sort(pairs,function(a,b)return a[1]<b[1]end);value=pairs
 elseif kind=='set' then value=redis.call('SMEMBERS',key);table.sort(value)
 elseif kind=='list' then value=redis.call('LRANGE',key,0,-1)
 elseif kind=='zset' then value=redis.call('ZRANGE',key,0,-1,'WITHSCORES')
 elseif kind=='stream' then value={redis.call('XRANGE',key,'-','+'),redis.call('XINFO','GROUPS',key)}
 elseif kind~='none' then return redis.error_reply('Unsupported Redis recovery type') end
 if kind~='none' then entries[hex(key)]={type=kind,expires=redis.call('PEXPIRETIME',key),value=bytes(value)} end
end
return cjson.encode({at=now,entries=entries})
`;
export const POSTGRES_PROOF=String.raw`
SELECT jsonb_build_object(
 'columns',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY table_schema,table_name,ordinal_position) FROM (SELECT table_schema,table_name,column_name,ordinal_position,column_default,is_nullable,data_type,udt_schema,udt_name FROM information_schema.columns WHERE table_schema NOT LIKE 'pg_%' AND table_schema<>'information_schema') c),'[]'::jsonb),
 'indexes',COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY schemaname,tablename,indexname) FROM (SELECT schemaname,tablename,indexname,indexdef FROM pg_indexes WHERE schemaname NOT LIKE 'pg_%' AND schemaname<>'information_schema') i),'[]'::jsonb),
 'constraints',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY namespace,relation,name) FROM (SELECT n.nspname AS namespace,c.conrelid::regclass::text AS relation,c.conname AS name,pg_get_constraintdef(c.oid,true) AS definition FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname<>'information_schema') c),'[]'::jsonb),
 'sequences',COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY schemaname,sequencename) FROM (SELECT schemaname,sequencename,start_value,min_value,max_value,increment_by,cycle,cache_size,last_value FROM pg_sequences WHERE schemaname NOT LIKE 'pg_%' AND schemaname<>'information_schema') s),'[]'::jsonb)
)::text;
SELECT format('SELECT jsonb_build_object(''schema'',%L,''table'',%L,''rows'',COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),''[]''::jsonb))::text FROM %I.%I t;',schemaname,tablename,schemaname,tablename) FROM pg_tables WHERE schemaname NOT LIKE 'pg_%' AND schemaname<>'information_schema' ORDER BY schemaname,tablename
\gexec
`;
export function mongoProof(database:string){
 if(!/^[a-z][a-z0-9_-]{0,60}$/.test(database))throw Error('Invalid recovery database');
 return `const target=db.getSiblingDB(${JSON.stringify(database)}); const collections=target.getCollectionInfos().sort((a,b)=>a.name.localeCompare(b.name)); for(const info of collections){if(info.type!=='collection')throw Error('Unsupported recovery collection'); print(EJSON.stringify({collection:info.name,options:info.options,uuid:info.info?.uuid,indexes:target.getCollection(info.name).getIndexes().sort((a,b)=>a.name.localeCompare(b.name))},{relaxed:false})); const rows=target.getCollection(info.name).find().sort({_id:1});for(const row of rows)print(EJSON.stringify({collection:info.name,row},{relaxed:false}));}`;
}
