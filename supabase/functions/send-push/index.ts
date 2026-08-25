// Edge Function: send-push
//
// Sends a real Web Push notification to one user's subscribed device(s).
// Called from the client (index.html -> notifyPartner()) right after a
// notification row is inserted, passing the *recipient's* user_id.
//
// Uses the service role key so it can read `push_subscriptions` for a
// user other than the caller -- RLS on that table only allows a user to
// read their own row, on purpose, so this lookup can only happen here,
// server-side, never from the browser.
//
// Deploy with:
//   supabase functions deploy send-push
// Secrets required (set once):
//   supabase secrets set VAPID_PUBLIC_KEY=xxxx VAPID_PRIVATE_KEY=xxxx VAPID_SUBJECT=mailto:you@example.com

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import webpush from 'https://esm.sh/web-push@3.6.7'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const VAPID_PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY')!
const VAPID_PRIVATE_KEY = Deno.env.get('VAPID_PRIVATE_KEY')!
const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') || 'mailto:hello@twogether.app'

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY)

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // Verify the caller is a logged-in user (their JWT, not the service
    // role key) before we do anything on their behalf.
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
        status: 401,
        headers: corsHeaders,
      })
    }

    const callerClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      global: { headers: { Authorization: authHeader } },
    })
    const { data: userData, error: userErr } = await callerClient.auth.getUser()
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: 'Invalid session' }), {
        status: 401,
        headers: corsHeaders,
      })
    }
    const callerId = userData.user.id

    const { target_user_id, title, message, url } = await req.json()
    if (!target_user_id || !title) {
      return new Response(JSON.stringify({ error: 'target_user_id and title are required' }), {
        status: 400,
        headers: corsHeaders,
      })
    }

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY)

    // Only allow notifying your own partner, never an arbitrary user.
    const { data: callerProfile } = await admin
      .from('profiles')
      .select('pair_id')
      .eq('user_id', callerId)
      .maybeSingle()

    const { data: targetProfile } = await admin
      .from('profiles')
      .select('pair_id')
      .eq('user_id', target_user_id)
      .maybeSingle()

    if (
      !callerProfile ||
      !targetProfile ||
      callerProfile.pair_id !== targetProfile.pair_id ||
      target_user_id === callerId
    ) {
      return new Response(JSON.stringify({ error: 'Not your partner' }), {
        status: 403,
        headers: corsHeaders,
      })
    }

    const { data: sub, error: subErr } = await admin
      .from('push_subscriptions')
      .select('subscription')
      .eq('user_id', target_user_id)
      .maybeSingle()

    if (subErr || !sub) {
      // Partner just hasn't enabled push yet -- not an error, the in-app
      // notification row already covers the bell icon.
      return new Response(JSON.stringify({ sent: false, reason: 'no subscription' }), {
        status: 200,
        headers: corsHeaders,
      })
    }

    try {
      await webpush.sendNotification(
        sub.subscription,
        JSON.stringify({ title, body: message || '', url: url || '/index.html' })
      )
      return new Response(JSON.stringify({ sent: true }), { status: 200, headers: corsHeaders })
    } catch (pushErr: any) {
      // 410/404 = the subscription expired or was revoked by the browser;
      // clean it up so we stop trying.
      if (pushErr?.statusCode === 410 || pushErr?.statusCode === 404) {
        await admin.from('push_subscriptions').delete().eq('user_id', target_user_id)
      }
      console.error('web-push send failed:', pushErr)
      return new Response(JSON.stringify({ sent: false, error: String(pushErr) }), {
        status: 200,
        headers: corsHeaders,
      })
    }
  } catch (err) {
    console.error(err)
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: corsHeaders })
  }
})
