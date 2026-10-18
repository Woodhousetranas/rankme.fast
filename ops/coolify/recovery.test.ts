import {test,expect} from 'bun:test';
import {canonical,redisMatches,postgresMatches,type RedisProof} from './recovery-proof';
import {validateIntent} from './recovery';

test('Redis recovery keeps delayed job data and absolute expiry while allowing elapsed TTLs',()=>{
 const before:RedisProof={at:1000,entries:{job:{type:'hash',expires:-1,value:[['data','opaque'],['delay','60000']]},session:{type:'string',expires:2000,value:'session'},cache:{type:'string',expires:1400,value:'cache'}}};
 const after:RedisProof={at:1500,entries:{job:before.entries.job,session:before.entries.session}};
 expect(redisMatches(before,after)).toBe(true);
 expect(redisMatches(before,{...after,entries:{session:before.entries.session}})).toBe(false);
 expect(redisMatches(before,{...after,entries:{...after.entries,session:{...before.entries.session,expires:2200}}})).toBe(false);
 expect(()=>redisMatches(before,{...after,at:500})).toThrow();
 expect(canonical({b:1,a:[2,3]})).toBe(canonical({a:[2,3],b:1}));
});
test('the independent guard accepts only exact RankMeFast application identities',()=>{
 const originals=Object.fromEntries(['api','web','worker'].map((name,i)=>[name,{id:String(i+2).repeat(64),image:'sha256:'+'a'.repeat(64)}]));
 const intent={jobId:'1'.repeat(64),jobName:'rankme-recovery-coolify-20261018-1234abcd',originals} as Parameters<typeof validateIntent>[0];
 expect(validateIntent(intent)).toBe(intent);
 expect(()=>validateIntent({...intent,jobName:'unrelated-task'})).toThrow();
 expect(()=>validateIntent({...intent,originals:{...intent.originals,worker:{id:'mutable-name',image:'latest'}}})).toThrow();
});
test('logical PostgreSQL restoration preserves column order after dropped attributes',()=>{
 const columns=[{table_schema:'public',table_name:'example',column_name:'a',ordinal_position:1},{table_schema:'public',table_name:'example',column_name:'b',ordinal_position:3}];
 const before=JSON.stringify({columns})+'\n{"value":9007199254740993}';
 const after=JSON.stringify({columns:[columns[0],{...columns[1],ordinal_position:2}]})+'\n{"value":9007199254740993}';
 expect(postgresMatches(before,after)).toBe(true);
 expect(postgresMatches(before,after.replace('9007199254740993','9007199254740992'))).toBe(false);
 expect(postgresMatches(before,JSON.stringify({columns:[{...columns[1],ordinal_position:1},{...columns[0],ordinal_position:2}]})+'\n{"value":9007199254740993}')).toBe(false);
 expect(()=>postgresMatches(before,JSON.stringify({columns:[columns[0],{...columns[1],ordinal_position:1}]}))).toThrow();
});
