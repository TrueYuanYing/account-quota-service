import {open,readdir,readFile,rename,unlink,link} from 'node:fs/promises';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

/** Single API replica. Only identifiers and trusted outcome are persisted, never text. */
export function modelJournal(directory) {
  const path=(user,request)=>{
    if(!UUID.test(user??'') || !UUID.test(request??''))throw new Error('invalid_journal_identity');
    return join(directory,user.toLowerCase()+'_'+request.toLowerCase()+'.json');
  };
  async function write(file,value,exclusive=false) {
    const target=file+'.tmp-'+randomUUID();
    try {
      const handle=await open(target,'wx',0o600);
      try {await handle.writeFile(JSON.stringify(value));await handle.sync();}
      finally {await handle.close();}
      // A hard link publishes an already-complete record without overwriting a
      // concurrent claim. No final .json ever contains a half-written document.
      if(exclusive)await link(target,file);
      else await rename(target,file);
      if(process.platform!=='win32') {
        const parent=await open(directory,'r');try{await parent.sync();}finally{await parent.close();}
      }
    }finally{await unlink(target).catch(error=>{if(error.code!=='ENOENT')throw error;});}
  }
  async function remove(user,request){await unlink(path(user,request)).catch(error=>{if(error.code!=='ENOENT')throw error;});}
  return {
    async start(user,request) {
      try {await write(path(user,request),{user,request,outcome:'pending'},true);return true;}
      catch(error){if(error.code==='EEXIST')return false;throw error;}
    },
    async attempted(user,request){await write(path(user,request),{user,request,outcome:'attempted'});},
    async terminal(user,request,success,{charge=success}={}){await write(path(user,request),{user,request,outcome:success?'succeeded':charge?'charged_failed':'failed'});},
    remove,
    async recover(settle,recordResult=null) {
      for(const name of await readdir(directory)) {
        if(!/^[a-f0-9-]{36}_[a-f0-9-]{36}\.json$/i.test(name))continue;
        const value=JSON.parse(await readFile(join(directory,name),'utf8'));
        if(Object.keys(value).sort().join(',')!=='outcome,request,user' ||
          path(value.user,value.request)!==join(directory,name.toLowerCase()) || !['pending','succeeded','failed','charged_failed','attempted'].includes(value.outcome))throw new Error('invalid_model_journal');
        try {
          // Recovery runs before listen, only after the previous single executor
          // has stopped. Pending precedes dispatch and can be released. An
          // attempted call consumes a quota even when its result remains unknown.
          await settle(value.user,value.request,['succeeded','charged_failed','attempted'].includes(value.outcome));
          if(recordResult && ['succeeded','charged_failed'].includes(value.outcome))
            await recordResult(value.user,value.request,value.outcome==='succeeded');
        }catch(error){if(!(error.code==='22023' && error.message==='unknown_request'))throw error;}
        await unlink(join(directory,name));
      }
    },
  };
}
