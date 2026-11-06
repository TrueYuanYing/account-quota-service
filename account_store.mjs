import {readFile} from 'node:fs/promises';
/** Values are parameterized. The caller supplies only a GoTrue-verified subject. */
export function accountStore(pool) {
  return {
    async adminOverview() {
      await pool.query('SELECT iko.expire_checkouts()');
      const result=await pool.query(`SELECT jsonb_build_object(
        'sampledAt',clock_timestamp(),
        'accounts',(SELECT count(*)::integer FROM iko.admin_accounts),
        'paidOrders',(SELECT count(*)::integer FROM iko.orders WHERE state='paid'),
        'pendingOrders',(SELECT count(*)::integer FROM iko.orders WHERE state='pending' AND created_at>clock_timestamp()-interval '15 minutes'),
        'paidCents',(SELECT coalesce(sum(price_cents),0) FROM iko.orders WHERE state='paid'),
        'openFeedback',(SELECT count(*)::integer FROM iko.feedback WHERE state<>'resolved'),
        'inFlight',(SELECT count(*)::integer FROM iko.usage_requests WHERE state='reserved'),
        'usage',(SELECT jsonb_agg(to_jsonb(q)) FROM (
          SELECT kinds.kind,count(r.request_id) FILTER(WHERE r.state='completed' AND r.result_valid=true)::integer AS "totalCalls",
            count(r.request_id) FILTER(WHERE r.state='completed')::integer AS "acceptedCalls",
            count(r.request_id) FILTER(WHERE r.state='completed' AND r.result_valid=false)::integer AS "chargedFailures",
            count(r.request_id) FILTER(WHERE r.state='completed' AND r.result_valid IS NULL)::integer AS "unknownCalls",
            count(r.request_id) FILTER(WHERE r.state='completed' AND r.result_valid=true AND r.finished_at>=(date_trunc('day',clock_timestamp() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai'))::integer AS "todayCalls",
            count(r.request_id) FILTER(WHERE r.state='reserved')::integer AS processing,
            count(r.request_id) FILTER(WHERE r.state='released')::integer AS "failedCalls"
          FROM (VALUES('answer'),('correct'),('translate'),('summary')) kinds(kind)
          LEFT JOIN iko.usage_requests r ON r.kind=kinds.kind GROUP BY kinds.kind) q),
        'todayUsage',(SELECT jsonb_object_agg(kinds.kind,coalesce(daily.calls,0)) FROM
          (VALUES('answer'),('correct'),('translate'),('summary')) kinds(kind) LEFT JOIN (
          SELECT kind,count(*)::integer AS calls FROM iko.usage_requests WHERE state='completed' AND result_valid=true
            AND finished_at>=(date_trunc('day',clock_timestamp() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai')
          GROUP BY kind) daily USING(kind))) AS overview`);
      let host=null;
      try {
        const value=JSON.parse(await readFile('/var/lib/iko-host-metrics/snapshot.json','utf8'));
        const sampled=Date.parse(value.sampledAt);
        const keys=['cpuPercent','cpuCores','memoryTotalBytes','memoryUsedBytes','diskTotalBytes','diskUsedBytes','uptimeSeconds'];
        if(Number.isFinite(sampled) && sampled<=Date.now()+5000 && Date.now()-sampled<180000 &&
            keys.every(key=>typeof value[key]==='number' && Number.isFinite(value[key]) && value[key]>=0))
          host=Object.fromEntries(['sampledAt',...keys].map(key=>[key,value[key]]));
      }catch{/* Optional/stale host snapshot must not block account management. */}
      return {...result.rows[0].overview,host,apiMemoryMb:Math.round(process.memoryUsage().rss/1048576),services:{account:'available',authentication:'verified',
        payment:process.env.ZPAY_ENABLED==='1'?'configured':process.env.ZPAY_TEST_USER?'trial':'not_open',
        model:process.env.ACCOUNT_PROXY_KEY?'configured':'not_configured'}};
    },
    async products() {
      return (await pool.query("SELECT id,name,price_cents,days,quotas FROM iko.products WHERE active OR id='trial_001' ORDER BY price_cents")).rows;
    },
    async saveProfile(user,name) {
      await pool.query(`INSERT INTO iko.account_documents(user_id,display_name) VALUES($1,$2)
        ON CONFLICT(user_id) DO UPDATE SET display_name=excluded.display_name`,[user,name]);
    },
    async identity(user) {
      const row=(await pool.query(`SELECT u.password_set AS "passwordSet",coalesce(d.display_name,'') AS "displayName",
        encode(d.avatar_jpeg,'base64') AS "avatarBase64",d.avatar_updated_at AS "avatarUpdatedAt",
        (SELECT count(*)::integer FROM iko.account_notifications n WHERE n.user_id=u.id AND n.read_at IS NULL) AS unread
        FROM iko.admin_accounts u LEFT JOIN iko.account_documents d ON d.user_id=u.id WHERE u.id=$1`,[user])).rows[0];
      return row?{...row,avatarBase64:row.avatarBase64?.replaceAll('\n','')??null}:{};
    },
    async saveAvatar(user,jpeg) {
      const result=await pool.query(`INSERT INTO iko.account_documents(user_id,avatar_jpeg,avatar_updated_at) VALUES($1,$2,clock_timestamp())
        ON CONFLICT(user_id) DO UPDATE SET avatar_jpeg=excluded.avatar_jpeg,avatar_updated_at=excluded.avatar_updated_at
        WHERE iko.account_documents.avatar_updated_at IS NULL OR iko.account_documents.avatar_updated_at<clock_timestamp()-interval '10 seconds'
        RETURNING user_id`,[user,jpeg]);
      if(!result.rowCount)throw Object.assign(new Error('avatar_rate_limited'),{code:'54000'});
    },
    async notifications(user) {
      return (await pool.query(`SELECT id,title,body,quotas,created_at AS "createdAt",read_at AS "readAt"
        FROM iko.account_notifications WHERE user_id=$1 ORDER BY created_at DESC,id LIMIT 50`,[user])).rows;
    },
    async readNotifications(user,ids) {
      await pool.query('UPDATE iko.account_notifications SET read_at=clock_timestamp() WHERE user_id=$1 AND ($2::uuid[] IS NULL OR id=ANY($2::uuid[])) AND read_at IS NULL',[user,ids]);
    },
    async submitFeedback(user,value) {
      return (await pool.query('SELECT iko.submit_feedback($1,$2,$3,$4,$5) AS id',
        [user,value.requestId,value.orderId,value.category,value.message])).rows[0].id;
    },
    async feedback(user) {
      return (await pool.query(`SELECT f.id,f.order_id AS "orderId",f.category,f.message,f.state,
        f.created_at AS "createdAt",f.updated_at AS "updatedAt",
        coalesce((SELECT a.reason FROM iko.admin_audit a WHERE a.target_id=f.id AND a.action='feedback_state'
          ORDER BY a.created_at DESC,a.request_id DESC LIMIT 1),'') AS reply,
        (SELECT max(a.created_at) FROM iko.admin_audit a WHERE a.target_id=f.id AND a.action='feedback_state') AS "repliedAt"
        FROM iko.feedback f WHERE f.user_id=$1 ORDER BY f.created_at DESC,f.id LIMIT 100`,[user])).rows;
    },
    async adminQuery(resource,{page,search}) {
      if(resource==='orders')await pool.query('SELECT iko.expire_checkouts()');
      const queries={
        usage:`SELECT u.id AS "userId",u.email,r.kind,count(*) FILTER(WHERE r.state='completed' AND r.result_valid=true)::integer AS "totalCalls",
          count(*) FILTER(WHERE r.state='completed')::integer AS "acceptedCalls",
          count(*) FILTER(WHERE r.state='completed' AND r.result_valid=false)::integer AS "chargedFailures",
          count(*) FILTER(WHERE r.state='completed' AND r.result_valid IS NULL)::integer AS "unknownCalls",
          count(*) FILTER(WHERE r.state='completed' AND r.result_valid=true AND r.finished_at>=(date_trunc('day',clock_timestamp() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai'))::integer AS "todayCalls",
          count(*) FILTER(WHERE r.state='released')::integer AS "failedCalls",count(*) FILTER(WHERE r.state='reserved')::integer AS processing,
          max(r.finished_at) FILTER(WHERE r.state='completed' AND r.result_valid=true) AS "lastSuccessAt"
          FROM iko.usage_requests r JOIN iko.admin_accounts u ON u.id=r.user_id
          WHERE strpos(lower(coalesce(u.email,'')),lower($1))>0 OR u.id::text=$1
          GROUP BY u.id,u.email,r.kind ORDER BY max(r.created_at) DESC,u.id,r.kind LIMIT 26 OFFSET $2`,
        accounts:`SELECT u.id,u.email,u.created_at AS "createdAt",u.last_sign_in_at AS "lastSignInAt",
          u.email_confirmed_at AS "emailConfirmedAt",u.password_set AS "passwordSet",
          coalesce(d.display_name,'') AS "displayName",(d.avatar_jpeg IS NOT NULL) AS "hasAvatar",
          (SELECT count(*)::integer FROM iko.orders o WHERE o.user_id=u.id AND o.state='paid') AS "paidOrders"
          FROM iko.admin_accounts u LEFT JOIN iko.account_documents d ON d.user_id=u.id
          WHERE strpos(lower(coalesce(u.email,'')),lower($1))>0 OR strpos(lower(coalesce(d.display_name,'')),lower($1))>0 OR u.id::text=$1
          ORDER BY u.created_at DESC,u.id LIMIT 26 OFFSET $2`,
        orders:`SELECT o.id,o.user_id AS "userId",u.email,o.product_id AS "productId",o.price_cents AS "priceCents",
          CASE WHEN o.state='pending' AND o.created_at<=clock_timestamp()-interval '15 minutes' THEN 'expired' ELSE o.state END AS state,
          o.created_at AS "createdAt",o.paid_at AS "paidAt",coalesce(e.revoked,false) AS revoked,
          coalesce((SELECT jsonb_agg(jsonb_build_object('kind',q.kind,'quota',q.quota,'used',q.used,'reserved',q.reserved))
            FROM iko.quota_balances q WHERE q.entitlement_id=e.id),'[]'::jsonb) AS balances
          FROM iko.orders o JOIN iko.admin_accounts u ON u.id=o.user_id
          LEFT JOIN iko.entitlements e ON e.order_id=o.id
          WHERE strpos(lower(coalesce(u.email,'')),lower($1))>0 OR o.id::text=$1 OR o.user_id::text=$1
          ORDER BY o.created_at DESC,o.id LIMIT 26 OFFSET $2`,
        feedback:`SELECT f.id,f.user_id AS "userId",u.email,f.order_id AS "orderId",f.category,f.message,
          f.state,f.created_at AS "createdAt",f.updated_at AS "updatedAt"
          FROM iko.feedback f JOIN iko.admin_accounts u ON u.id=f.user_id
          WHERE strpos(lower(coalesce(u.email,'')),lower($1))>0 OR f.id::text=$1
          ORDER BY f.created_at DESC,f.id LIMIT 26 OFFSET $2`,
        audit:`SELECT request_id AS id,actor_digest AS "actorDigest",action,target_id AS "targetId",
          reason,previous_state AS "previousState",next_state AS "nextState",created_at AS "createdAt"
          FROM iko.admin_audit WHERE $1='' OR target_id::text=$1
          ORDER BY created_at DESC,request_id LIMIT 26 OFFSET $2`,
      };
      if(!Object.hasOwn(queries,resource))throw new Error('unsupported_admin_query');
      const rows=(await pool.query(queries[resource],[search,(page-1)*25])).rows;
      return {rows:rows.slice(0,25),page,hasMore:rows.length>25};
    },
    async adminAction(actor,resource,value) {
      if(resource==='grant') {
        const result=await pool.query('SELECT iko.add_quota_grant($1,$2,$3,$4,$5) AS id',
          [actor,value.requestId,value.userId,JSON.stringify(value.quotas),value.reason.trim()]);
        return {changed:true,grantId:result.rows[0].id};
      }
      if(resource==='revoke') {
        await pool.query('SELECT iko.revoke_order($1,$2,$3,$4)',[actor,value.requestId,value.orderId,value.reason]);
        return {changed:true,moneyRefunded:false};
      }
      if(resource!=='feedback')throw new Error('unsupported_admin_action');
      const result=await pool.query('SELECT iko.update_feedback($1,$2,$3,$4,$5) AS state',
        [actor,value.requestId,value.feedbackId,value.state,value.reason]);
      return {state:result.rows[0].state};
    },
    async accountDocument(user) {
      await pool.query('SELECT iko.expire_checkouts()');
      const result=await pool.query(`SELECT jsonb_build_object(
        'profile',(SELECT jsonb_build_object('email',email,'createdAt',created_at,'lastSignInAt',last_sign_in_at,
          'emailConfirmedAt',email_confirmed_at,'passwordSet',password_set) FROM iko.admin_accounts WHERE id=$1),
        'displayName',coalesce((SELECT display_name FROM iko.account_documents WHERE user_id=$1),''),
        'grants',coalesce((SELECT jsonb_agg(to_jsonb(g)) FROM (SELECT id,quotas,reason,source_order_id AS "sourceOrderId",created_at AS "createdAt"
          FROM iko.quota_grants WHERE user_id=$1 ORDER BY created_at DESC,id LIMIT 30) g),'[]'::jsonb),
        'orders',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'productId',product_id,
          'priceCents',price_cents,'state',CASE WHEN state='pending' AND created_at<=clock_timestamp()-interval '15 minutes' THEN 'expired' ELSE state END,
          'createdAt',created_at,'paidAt',paid_at) ORDER BY created_at DESC)
          FROM (SELECT * FROM iko.orders WHERE user_id=$1 ORDER BY created_at DESC LIMIT 100) recent),'[]'::jsonb),
        'entitlements',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'startsAt',starts_at,
          'endsAt',ends_at,'revoked',revoked)) FROM iko.entitlements WHERE user_id=$1),'[]'::jsonb),
        'quota',(SELECT jsonb_agg(to_jsonb(balance)) FROM (
          SELECT kinds.kind,coalesce(stats.total,0) AS total,coalesce(stats.used,0) AS used,
            coalesce(stats.reserved,0) AS reserved,coalesce(stats.remaining,0) AS remaining
          FROM (VALUES('answer'),('correct'),('translate'),('summary')) kinds(kind)
          LEFT JOIN (SELECT b.kind,sum(b.quota)::integer AS total,sum(b.used)::integer AS used,
              sum(b.reserved)::integer AS reserved,sum(b.quota-b.used-b.reserved)::integer AS remaining
            FROM iko.quota_balances b JOIN iko.entitlements e ON e.id=b.entitlement_id
            WHERE e.user_id=$1 AND NOT e.revoked AND (e.ends_at IS NULL OR e.ends_at>clock_timestamp())
            GROUP BY b.kind) stats USING(kind)) balance),
        'todayUsage',(SELECT jsonb_object_agg(kinds.kind,coalesce(daily.calls,0)) FROM
          (VALUES('answer'),('correct'),('translate'),('summary')) kinds(kind) LEFT JOIN (
          SELECT kind,count(*)::integer AS calls FROM iko.usage_requests WHERE user_id=$1 AND state='completed' AND result_valid=true
            AND finished_at>=(date_trunc('day',clock_timestamp() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai')
          GROUP BY kind) daily USING(kind))
        ) AS document`,[user]);
      return result.rows[0].document;
    }
  };
}
