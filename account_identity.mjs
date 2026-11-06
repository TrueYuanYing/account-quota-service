const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
export function jpegAvatar(value) {
  if(value===null)return null;
  if(typeof value!=='string'||value.length>43692||! /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value))throw new Error('invalid_avatar');
  const data=Buffer.from(value,'base64');
  if(data.length<16||data.length>32768||data[0]!==255||data[1]!==216||data.at(-2)!==255||data.at(-1)!==217)throw new Error('invalid_avatar');
  let at=2,dimensions=false;
  while(at+4<data.length) {
    if(data[at++]!==255)throw new Error('invalid_avatar');
    while(data[at]===255)at++;
    const marker=data[at++];if(marker===218)break;
    const size=data.readUInt16BE(at);if(size<2||at+size>data.length)throw new Error('invalid_avatar');
    if([192,193,194].includes(marker)){
      if(size<8)throw new Error('invalid_avatar');
      const height=data.readUInt16BE(at+3),width=data.readUInt16BE(at+5);
      if(width<1||height<1||width>256||height>256)throw new Error('invalid_avatar');
      dimensions=true;
    }
    at+=size;
  }
  if(!dimensions)throw new Error('invalid_avatar');
  return data;
}
async function body(req) {
 if(!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type']??''))return null;
 const parts=[];let size=0;
 for await(const part of req){size+=part.length;if(size>48000)return null;parts.push(part);}
 try{const value=JSON.parse(Buffer.concat(parts));return value&&typeof value==='object'&&!Array.isArray(value)?value:null;}catch{return null;}
}
export async function accountIdentity(req,res,{store,user,reply,path,capacity}) {
 if(path==='/v1/me/profile'&&req.method==='GET')return reply(res,200,{...await store.identity(user.id),passwordSet:user.user_metadata?.iko_password_set===true});
 if(path==='/v1/me/avatar'&&req.method==='PUT') {
  const value=await body(req);
  if(!value||Object.keys(value).length!==1||!Object.hasOwn(value,'jpegBase64'))return reply(res,400,{error:'invalid_avatar'});
  let jpeg;try{jpeg=jpegAvatar(value.jpegBase64);}catch{return reply(res,400,{error:'invalid_avatar'});}
  if(capacity && !(await capacity.refresh())?.writesAllowed)return reply(res,503,{error:'service_unavailable'});
  await store.saveAvatar(user.id,jpeg);return reply(res,200,{...await store.identity(user.id),passwordSet:user.user_metadata?.iko_password_set===true});
 }
 if(req.method==='GET')return reply(res,200,{rows:await store.notifications(user.id)});
 const value=await body(req);
 if(value&&Object.keys(value).length===1&&value.all===true){
  await store.readNotifications(user.id,null);return reply(res,200,{updated:true});
 }
 if(!value||Object.keys(value).length!==1||!Array.isArray(value.ids)||!value.ids.length||value.ids.length>50||value.ids.some(id=>!UUID.test(id)))return reply(res,400,{error:'invalid_notification'});
 await store.readNotifications(user.id,value.ids);return reply(res,200,{updated:true});
}
