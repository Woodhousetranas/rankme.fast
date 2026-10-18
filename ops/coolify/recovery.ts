import {createHash} from 'node:crypto';
import {readFile,writeFile,mkdir,chmod,lstat,rename,open} from 'node:fs/promises';
import {resolve,join,dirname} from 'node:path';
import {canonical,REDIS_PROOF,POSTGRES_PROOF,mongoProof,redisMatches,postgresMatches,type RedisProof} from './recovery-proof';

const ROOT=resolve(import.meta.dir,'../..');
const CONTROL=join(ROOT,'data','coolify-recovery');
const SERVICES=['api','web','worker','mongo','postgres','redis'] as const;
const APPS=['api','web','worker'] as const;
type Service=typeof SERVICES[number];
type Runtime={id:string;image:string;env:Record<string,string>};
type Original=Record<Service,Runtime>;
type Intent={jobId:string;jobName:string;originals:Record<typeof APPS[number],Pick<Runtime,'id'|'image'>>};
class SafeError extends Error{}
function check(value:unknown,message:string):asserts value{if(!value)throw new SafeError(message);}
const emit=(step:string,extra:Record<string,unknown>={})=>console.log(JSON.stringify({at:new Date().toISOString(),step,...extra}));
const imageId=(value:unknown):value is string=>typeof value==='string'&&/^sha256:[a-f0-9]{64}$/.test(value);
const containerId=(value:unknown):value is string=>typeof value==='string'&&/^[a-f0-9]{64}$/.test(value);
async function privateDir(path:string){
 let current=resolve(path);for(;;){try{const info=await lstat(current);check(!info.isSymbolicLink(),'Recovery path contains a symlink');}catch(error){if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error;}const parent=dirname(current);if(parent===current)break;current=parent;}
 await mkdir(path,{recursive:true,mode:0o700});await chmod(path,0o700);
}
async function privateWrite(path:string,value:string|Uint8Array){await privateDir(dirname(path));const temp=path+'.'+crypto.randomUUID()+'.tmp';await writeFile(temp,value,{mode:0o600,flag:'wx'});await rename(temp,path);await chmod(path,0o600);}
async function hashFile(path:string){const hash=createHash('sha256');const reader=Bun.file(path).stream().getReader();try{for(;;){const part=await reader.read();if(part.done)break;hash.update(part.value);}return hash.digest('hex');}finally{reader.releaseLock();}}
type Options={input?:Uint8Array;inputFile?:string;output?:string;env?:Record<string,string>};
async function run(argv:string[],label:string,options:Options={}):Promise<string>{
 const output=options.output?await open(options.output,'wx',0o600):undefined;
 const input=options.inputFile?await open(options.inputFile,'r'):undefined;
 try{
  const child=Bun.spawn(argv,{cwd:ROOT,env:{...process.env,...options.env},stdin:input?.fd??options.input??'ignore',stdout:output?.fd??'pipe',stderr:'pipe'});
  const [text]=await Promise.all([output?Promise.resolve(''):new Response(child.stdout as ReadableStream).text(),new Response(child.stderr).text()]);
  check(await child.exited===0,label+' failed');await output?.sync();return text.trim();
 }finally{await output?.close();await input?.close();}
}
async function inspect(id:string){return JSON.parse(await run(['docker','inspect',id],'Inspect scoped recovery container'))[0];}
function envMap(values:string[]){return Object.fromEntries(values.map(value=>{const position=value.indexOf('=');return [value.slice(0,position),value.slice(position+1)];}));}
async function originals():Promise<Original>{
 const result={} as Original;
 for(const service of SERVICES){const value=await inspect('rankme-'+service+'-1');check(value.Config.Labels?.['com.docker.compose.project']==='rankme'&&value.Config.Labels?.['com.docker.compose.service']===service&&value.State.Running&&value.State.Health?.Status==='healthy'&&containerId(value.Id)&&imageId(value.Image),'Original service is not healthy or has changed identity');check((await run(['docker','image','inspect',value.Image,'--format','{{.Id}}'],'Resolve exact original image'))===value.Image,'Original image unavailable');result[service]={id:value.Id,image:value.Image,env:envMap(value.Config.Env)};}
 const api=result.api.env;for(const name of ['MASTER_ENCRYPTION_KEY','BETTER_AUTH_SECRET','DATABASE_URL','MONGODB_URI','REDIS_URL'])check(!!api[name]&&api[name]===result.worker.env[name],'Original API and worker private configuration differ');
 const pg=new URL(api.DATABASE_URL);const mongo=new URL(api.MONGODB_URI);const redis=new URL(api.REDIS_URL);
 check(pg.hostname==='postgres'&&decodeURIComponent(pg.password)===result.postgres.env.POSTGRES_PASSWORD&&decodeURIComponent(pg.username)===result.postgres.env.POSTGRES_USER&&pg.pathname==='/'+result.postgres.env.POSTGRES_DB,'PostgreSQL runtime binding mismatch');
 check(mongo.hostname==='mongo'&&!mongo.username&&!mongo.password&&redis.hostname==='redis'&&!redis.username&&!redis.password,'This original-stack adapter requires the installed private Mongo/Redis profile');
 return result;
}
function sameOriginals(left:Original,right:Original){return SERVICES.every(service=>left[service].id===right[service].id&&left[service].image===right[service].image&&canonical(left[service].env)===canonical(right[service].env));}
function queueNames(){const text=Bun.file(join(ROOT,'server','src','shared','queue','queues.ts'));return text.text().then(source=>[...new Set(Array.from(source.matchAll(/export const [A-Z0-9_]+_QUEUE = '([^']+)'/g),item=>item[1]))].sort());}
async function requireIdle(original:Original){const names=await queueNames();check(names.length===24,'Review the changed queue inventory before backup');const code=names.map(name=>`if redis.call('LLEN',${JSON.stringify('bull:'+name+':active')})>0 then return 1 end`).join(';')+'; return 0';const result=await run(['docker','exec',original.redis.id,'redis-cli','--raw','EVAL',code,'0'],'Check active worker jobs');check(result==='0','Active jobs prevent maintenance; retry after they settle');}
async function snapshot(original:Original){
 const pg=await run(['docker','exec','-i',original.postgres.id,'sh','-c','exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -A -t -q --set ON_ERROR_STOP=1'],'Read complete PostgreSQL data/schema',{input:new TextEncoder().encode(POSTGRES_PROOF)});
 const db=new URL(original.api.env.MONGODB_URI).pathname.slice(1);
 const mongo=await run(['docker','exec',original.mongo.id,'mongosh','--quiet','--eval',mongoProof(db)],'Read complete MongoDB data/indexes');
 const outer=JSON.parse(await run(['docker','exec',original.redis.id,'redis-cli','--json','EVAL',REDIS_PROOF,'0'],'Read atomic Redis data and expiry state'));
 const redis=JSON.parse(outer) as RedisProof;
 check(pg.split('\n').every(line=>{try{JSON.parse(line);return true;}catch{return false;}})&&mongo.split('\n').every(line=>{try{JSON.parse(line);return true;}catch{return false;}}),'Malformed database recovery proof');
 return {postgres:pg,mongo,redis};
}
function matches(before:Awaited<ReturnType<typeof snapshot>>,after:Awaited<ReturnType<typeof snapshot>>){check(postgresMatches(before.postgres,after.postgres),'Restored PostgreSQL data/schema differs');check(before.mongo===after.mongo,'Restored MongoDB documents/indexes differ');check(redisMatches(before.redis,after.redis),'Restored Redis data/expiry/queues differ');}
export function validateIntent(intent:Intent){
 check(containerId(intent?.jobId)&&/^rankme-recovery-coolify-[0-9]{8}-[a-f0-9]{8}$/.test(intent.jobName),'Invalid recovery job identity');
 check(Object.keys(intent.originals??{}).sort().join(',')==='api,web,worker'&&APPS.every(service=>containerId(intent.originals[service].id)&&imageId(intent.originals[service].image)),'Invalid original application identities');return intent;
}
async function resume(intent:Intent){
 validateIntent(intent);for(const service of APPS){const expected=intent.originals[service];const actual=await inspect(expected.id);check(actual.Config.Labels?.['com.docker.compose.project']==='rankme'&&actual.Config.Labels?.['com.docker.compose.service']===service&&actual.Image===expected.image,'Original application changed during maintenance');await run(['docker','start',expected.id],'Resume exact original application');}
}
async function waitHealthy(ids:string[]){const until=Date.now()+90000;for(;;){const states=await Promise.all(ids.map(inspect));if(states.every(value=>value.State.Running&&value.State.Health?.Status==='healthy'))return;check(Date.now()<until,'Scoped services did not recover healthy');await Bun.sleep(1000);}}
async function guard(){
 const intent=validateIntent(JSON.parse(await readFile(join(CONTROL,'intent.json'),'utf8')));let started=false,ready=false;
 for(;;){const value=await inspect(intent.jobId);check(value.Name==='/'+intent.jobName,'Recovery job identity changed');if(!ready){emit('Recovery guard ready');ready=true;}if(value.State.Running||!value.State.StartedAt.startsWith('0001-'))started=true;if(started&&['exited','dead'].includes(value.State.Status))break;await Bun.sleep(1500);}
 await resume(intent);await waitHealthy(APPS.map(service=>intent.originals[service].id));await privateWrite(join(CONTROL,'guard-resumed.json'),JSON.stringify({at:new Date().toISOString(),originalApplicationsHealthy:true}));emit('Exact original applications resumed by independent guard');for(;;)await Bun.sleep(60000);
}
async function preflight(){
 const original=await originals();await sourceEnvironment(original);await requireIdle(original);await snapshot(original);
 await privateWrite(join(CONTROL,'original.json'),JSON.stringify(original));emit('Original-stack preflight passed',{services:6,queues:24,activeJobs:0,privateValuesPrinted:false});return original;
}
function rootEnvironmentValue(source:string,key:string){const line=source.split(/\r?\n/).find(line=>line.startsWith(key+'='));if(!line)return '';let value=line.slice(key.length+1).trim();if((value.startsWith('"')&&value.endsWith('"'))||(value.startsWith("'")&&value.endsWith("'")))value=value.slice(1,-1);return value;}
async function sourceEnvironment(original:Original){const info=await lstat('/live-source/.env');check(info.isFile()&&!info.isSymbolicLink()&&info.size<1024*1024,'Original root environment must be a regular file');const value=await readFile('/live-source/.env');for(const key of ['MASTER_ENCRYPTION_KEY','BETTER_AUTH_SECRET'])check(rootEnvironmentValue(value.toString('utf8'),key)===original.api.env[key],'Original root environment and running encryption/session keys differ');return value;}
function backupPath(id:string){check(/^coolify-[0-9]{8}-[a-f0-9]{8}$/.test(id),'Invalid operation id');const path=resolve(ROOT,'..','backups',id);check(path.startsWith('/var/lib/docker/volumes/coolify-rankme-recovery-'),'Use the dedicated Docker operations volume');return path;}
async function backup(id:string,revision:string){
 const destination=backupPath(id);check(/^[a-f0-9]{40}$/.test(revision),'Committed source revision required');
 const original=await originals();const expected=JSON.parse(await readFile(join(CONTROL,'original.json'),'utf8'));check(sameOriginals(expected,original),'Original runtime changed after preflight');await requireIdle(original);
 const intent=validateIntent(JSON.parse(await readFile(join(CONTROL,'intent.json'),'utf8')));check(APPS.every(service=>intent.originals[service].id===original[service].id),'Guard and backup identities differ');
 await privateDir(destination);await privateDir(join(destination,'private'));let baseline:Awaited<ReturnType<typeof snapshot>>;
 try{
  emit('Pause original API and web');await run(['docker','stop','--time','60',original.api.id,original.web.id],'Pause request producers');await requireIdle(original);
  emit('Pause idle original worker');await run(['docker','stop','--time','60',original.worker.id],'Drain worker');const stopped=await inspect(original.worker.id);check(stopped.State.ExitCode===0,'Worker did not shut down cleanly');await requireIdle(original);
  emit('Capture complete database, document and queued-work baseline');baseline=await snapshot(original);
  await privateWrite(join(destination,'baseline.json'),JSON.stringify(baseline));await privateWrite(join(destination,'private','original-runtime.json'),JSON.stringify(original));
  await privateWrite(join(destination,'private','root-env'),await sourceEnvironment(original));
  emit('Create PostgreSQL logical backup');await run(['docker','exec',original.postgres.id,'sh','-c','exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-acl'],'Dump original PostgreSQL',{output:join(destination,'postgres.dump')});
  emit('Create MongoDB document and index archive');await run(['docker','exec',original.mongo.id,'mongodump','--archive','--gzip','--db',new URL(original.api.env.MONGODB_URI).pathname.slice(1)],'Dump original MongoDB',{output:join(destination,'mongo.archive.gz')});
  emit('Create consistent Redis RDB including delayed jobs');const temp='/tmp/rankme-'+id+'.rdb';
  try{await run(['docker','exec',original.redis.id,'sh','-c','set -eu; umask 077; test ! -e "$1"; redis-cli --rdb "$1"','rankme-rdb',temp],'Snapshot original Redis');await run(['docker','cp',original.redis.id+':'+temp,join(destination,'redis.rdb')],'Copy private Redis snapshot');await chmod(join(destination,'redis.rdb'),0o600);}
  finally{await run(['docker','exec',original.redis.id,'rm','-f',temp],'Remove exact temporary Redis snapshot');}
  matches(baseline,await snapshot(original));
  const files=['baseline.json','private/original-runtime.json','private/root-env','postgres.dump','mongo.archive.gz','redis.rdb'];const hashes:Record<string,string>={};for(const file of files)hashes[file]=await hashFile(join(destination,file));
  await privateWrite(join(destination,'manifest.json'),JSON.stringify({version:1,project:'rankme',sourceRevision:revision,createdAt:new Date().toISOString(),hashes,masterAndSessionKeysPreserved:true,providerCalled:false},null,2));
 }finally{emit('Resume original applications');await resume(intent);await waitHealthy(SERVICES.map(service=>original[service].id));}
 check(sameOriginals(original,await originals()),'Original runtime identity/configuration changed');emit('Consistent application backup completed',{originalServicesHealthy:true,providerCalled:false});return destination;
}

export function validateRestoreProject(id:string){check(/^coolify-[0-9]{8}-[a-f0-9]{8}$/.test(id),'Invalid isolated recovery id');return 'rankme-restore-'+id;}
async function verifyBackup(path:string){
 const match=/^\/var\/lib\/docker\/volumes\/coolify-rankme-recovery-([0-9]{8})-([a-f0-9]{8})\/_data\/backups\/coolify-([0-9]{8})-([a-f0-9]{8})$/.exec(path);
 check(match&&match[1]===match[3]&&match[2]===match[4],'Invalid original backup path');
 const manifest=JSON.parse(await readFile(join(path,'manifest.json'),'utf8'));
 const files=['baseline.json','private/original-runtime.json','private/root-env','postgres.dump','mongo.archive.gz','redis.rdb'];
 check(manifest.version===1&&manifest.project==='rankme'&&canonical(Object.keys(manifest.hashes??{}).sort())===canonical(files.sort()),'Invalid backup manifest');
 for(const file of files){const target=join(path,file);const info=await lstat(target);check(info.isFile()&&!info.isSymbolicLink()&&manifest.hashes[file]===await hashFile(target),'Backup integrity mismatch');}
 return manifest;
}
async function createDatabase(project:string,service:'mongo'|'postgres'|'redis',original:Runtime,volume:string,aof=false){
 const name=project+'-'+service;const health=service==='mongo'?`mongosh --quiet --eval "db.adminCommand('ping').ok"`:service==='postgres'?'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"':'redis-cli ping';
 const argv=['docker','run','-d','--name',name,'--label','com.docker.compose.project='+project,'--label','com.docker.compose.service='+service,'--network',project,'--network-alias',service,'--memory',service==='redis'?'256m':'512m','--cpus',service==='redis'?'0.25':'0.5','--pids-limit','256','--security-opt','no-new-privileges:true','--log-opt','max-size=10m','--log-opt','max-file=3','--health-cmd',health,'--health-interval','2s','--health-timeout','5s','--health-retries','30','--mount',`type=volume,source=${volume},target=${service==='mongo'?'/data/db':service==='postgres'?'/var/lib/postgresql/data':'/data'}`];
 const env:Record<string,string>={};if(service==='postgres')for(const key of ['POSTGRES_USER','POSTGRES_PASSWORD','POSTGRES_DB']){env[key]=original.env[key];check(!!env[key],'PostgreSQL recovery configuration missing');argv.push('--env',key);}
 argv.push(original.image);if(service==='redis')argv.push('redis-server','--appendonly',aof?'yes':'no','--save','');
 const id=await run(argv,'Create isolated '+service,{env});check(containerId(id),'Invalid isolated database identity');return {id,image:original.image,env:original.env};
}
async function restore(path:string,id:string){
 const manifest=await verifyBackup(path);const project=validateRestoreProject(id);
 const original=JSON.parse(await readFile(join(path,'private','original-runtime.json'),'utf8')) as Original;
 const baseline=JSON.parse(await readFile(join(path,'baseline.json'),'utf8')) as Awaited<ReturnType<typeof snapshot>>;
 for(const service of ['mongo','postgres','redis'] as const){check(imageId(original[service].image),'Invalid original database image');await run(['docker','image','inspect',original[service].image],'Resolve exact recovery database image');}
 check(!(await run(['docker','ps','-a','--filter','label=com.docker.compose.project='+project,'--format','{{.ID}}'],'Check isolated container destination'))&&!(await run(['docker','volume','ls','--filter','label=com.docker.compose.project='+project,'--format','{{.Name}}'],'Check isolated data destination')),'Isolated destination already exists');
 const volumes={} as Record<'mongo'|'postgres'|'redis',string>;const created:string[]=[];
 const dir=join(CONTROL,'restore',id);await privateDir(dir);
 try{
  emit('Create isolated internal database network');await run(['docker','network','create','--internal','--label','com.docker.compose.project='+project,project],'Create isolated internal network');
  for(const service of ['mongo','postgres','redis'] as const){const volume=project+'_'+service+'-data';check((await run(['docker','volume','ls','--format','{{.Name}}'],'Check exact fresh volume')).split('\n').every(value=>value!==volume),'Recovery volume already exists');await run(['docker','volume','create','--label','com.docker.compose.project='+project,'--label','com.docker.compose.volume='+service+'-data',volume],'Create fresh isolated volume');volumes[service]=volume;}
  const runtime={...original};
  for(const service of ['mongo','postgres'] as const){runtime[service]=await createDatabase(project,service,original[service],volumes[service]);created.push(runtime[service].id);}
  // Docker's Redis entrypoint changes ownership of its dedicated volume.
  const helperImage=process.env.RECOVERY_MAINTENANCE_IMAGE;check(imageId(helperImage),'Exact maintenance image required');
  await run(['docker','run','--rm','--network','none','--user','0','--memory','128m','--cpus','0.5','--pids-limit','64','--mount',`type=volume,source=${volumes.redis},target=/target`,'--mount',`type=bind,source=${path},target=/backup,readonly`,'--entrypoint','sh',helperImage,'-c','set -eu; test -z "$(ls -A /target)"; cp /backup/redis.rdb /target/dump.rdb; chmod 600 /target/dump.rdb'],'Stage isolated Redis RDB');
  runtime.redis=await createDatabase(project,'redis',original.redis,volumes.redis);created.push(runtime.redis.id);
  await waitHealthy(created);
  emit('Restore MongoDB documents and indexes');await run(['docker','exec','-i',runtime.mongo.id,'mongorestore','--archive','--gzip','--drop','--preserveUUID','--nsInclude',new URL(original.api.env.MONGODB_URI).pathname.slice(1)+'.*'],'Restore isolated MongoDB',{inputFile:join(path,'mongo.archive.gz')});
  emit('Restore PostgreSQL schemas, migration history and rows');await run(['docker','exec','-i',runtime.postgres.id,'sh','-c','exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl --exit-on-error'],'Restore isolated PostgreSQL',{inputFile:join(path,'postgres.dump')});
  emit('Compare all database rows, indexes and Redis contents');matches(baseline,await snapshot(runtime));
  // Build and qualify AOF from the recovered RDB before using the production
  // Redis command. This avoids booting an empty AOF over a valid RDB.
  await run(['docker','exec',runtime.redis.id,'redis-cli','CONFIG','SET','appendonly','yes'],'Enable persistence on isolated restored Redis');
  const until=Date.now()+60000;for(;;){const info=await run(['docker','exec',runtime.redis.id,'redis-cli','INFO','persistence'],'Check isolated AOF rewrite');if(info.includes('aof_rewrite_in_progress:0')&&info.includes('aof_last_bgrewrite_status:ok'))break;check(Date.now()<until,'Restored Redis AOF rewrite did not finish');await Bun.sleep(500);}
  emit('Verify database restart and delayed-job persistence');await run(['docker','stop','--time','30',...created],'Stop isolated stores for recovery restart');await run(['docker','rm',runtime.redis.id],'Replace only isolated Redis fixture');created.splice(created.indexOf(runtime.redis.id),1);
  await run(['docker','start',runtime.mongo.id,runtime.postgres.id],'Restart isolated MongoDB/PostgreSQL');runtime.redis=await createDatabase(project,'redis',original.redis,volumes.redis,true);created.push(runtime.redis.id);await waitHealthy(created);matches(baseline,await snapshot(runtime));
  const receipt={version:1,project,completedAt:new Date().toISOString(),sourceRevision:manifest.sourceRevision,restoreVerifierRevision:arg('revision'),completeSqlDataAndSchemaMatch:true,sqlColumnOrderPreserved:true,droppedPhysicalColumnGapsNormalized:true,mongoDocumentsAndIndexMetadataMatch:true,completeRedisLogicalDataMatch:true,absoluteRedisExpiryPreserved:true,redisAofRestartVerified:true,originalApplicationsStopped:false,apiStarted:false,workerStarted:false,providerCalled:false,masterAndSessionKeysRecovered:true,isolatedPorts:[],isolatedNetworkInternal:true};
  await privateWrite(join(dir,'verified.json'),JSON.stringify(receipt,null,2));await privateWrite(join(path,'recovery-verified.json'),JSON.stringify(receipt,null,2));emit('Complete isolated application restore verified',{providerCalled:false,apiStarted:false,workerStarted:false});return receipt;
 }finally{if(created.length){emit('Stop isolated test stores and retain recovered volumes');await run(['docker','stop','--time','30',...created],'Stop scoped restore containers');}}
}
async function testGuard(id:string,image:string){
 check(imageId(image),'Exact fixture image required');const name='rankme-recovery-'+id;validateRestoreProject(id);const created:string[]=[];const fixtures={} as Intent['originals'];
 try{
  for(const service of APPS){const fixture=await run(['docker','create','--name',name+'-fixture-'+service,'--label','com.docker.compose.project=rankme','--label','com.docker.compose.service='+service,'--network','none','--memory','64m','--cpus','0.1','--pids-limit','32','--health-cmd','true','--health-interval','1s','--entrypoint','sh',image,'-c','sleep 300'],'Create disposable guard fixture');check(containerId(fixture),'Invalid fixture identity');created.push(fixture);fixtures[service]={id:fixture,image};}
  const jobId=await run(['docker','create','--name',name,'--network','none','--memory','64m','--cpus','0.1','--entrypoint','sh',image,'-c','sleep 300'],'Create disposable stopped-job test');check(containerId(jobId),'Invalid guard test job');created.push(jobId);
  await privateWrite(join(CONTROL,'intent.json'),JSON.stringify({jobId,jobName:name,originals:fixtures}));await run(['docker','start',jobId],'Start disposable test job');
  const volume=ROOT.split('/')[5];check(volume.startsWith('coolify-rankme-recovery-'),'Unexpected operations volume');const mount='/var/lib/docker/volumes/'+volume+'/_data';
  const guardId=await run(['docker','run','-d','--name',name+'-guard-fixture','--network','none','--user','1000:1000','--group-add','0','--memory','128m','--cpus','0.25','--pids-limit','64','--cap-drop','ALL','--security-opt','no-new-privileges:true','--mount',`type=volume,source=${volume},target=${mount}`,'--mount','type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock','--workdir',ROOT,image,join(ROOT,'ops','coolify','recovery.ts'),'--mode=guard'],'Start independent test guard');check(containerId(guardId),'Invalid fixture guard');created.push(guardId);
  const until=Date.now()+15000;for(;;){const logs=await run(['docker','logs',guardId],'Read controlled fixture guard signal');if(logs.includes('Recovery guard ready'))break;check(Date.now()<until,'Fixture guard never became ready');await Bun.sleep(250);}
  await run(['docker','kill','--signal','KILL',jobId],'Kill only disposable test job');await waitHealthy(APPS.map(service=>fixtures[service].id));await privateWrite(join(CONTROL,'guard-test.json'),JSON.stringify({at:new Date().toISOString(),sigkillRecoveryVerified:true,originalContainersChanged:false}));emit('Independent guard SIGKILL test passed',{disposableApplicationsStarted:3,originalApplicationsChanged:false});
 }finally{for(const container of created.reverse())await run(['docker','rm','-f',container],'Remove exact disposable fixture');}
}

const arg=(name:string)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??'';
if(import.meta.main){
 const mode=arg('mode');
 const action=async()=>{check(process.platform==='linux'&&process.getuid?.()===1000&&ROOT.startsWith('/var/lib/docker/volumes/'),'Use the non-root Docker maintenance helper');await privateDir(CONTROL);if(mode==='preflight')await preflight();else if(mode==='guard')await guard();else if(mode==='backup'){const path=await backup(arg('id'),arg('revision'));await restore(path,arg('id'));}else if(mode==='restore')await restore(arg('backup'),arg('id'));else if(mode==='test-guard')await testGuard(arg('id'),arg('image'));else throw new SafeError('Invalid recovery mode');};
 action().catch(error=>{emit('Recovery operation failed',{error:error instanceof SafeError?error.message:'Unexpected failure; private output suppressed'});process.exitCode=1;});
}
