import {test,expect} from 'bun:test';
import {canonical,redisMatches,type RedisProof} from './recovery-proof';
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
