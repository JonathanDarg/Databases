// whoami: an Edge Function (TypeScript on Deno, running on Supabase's edge runtime).
//
// Edge Functions are where server-side logic goes: calling third-party APIs with secret
// keys, webhooks, sending email, heavy validation, or anything you can't trust a
// browser to do.
//
// withSupabase({ auth: 'user' }) rejects any request without a valid user JWT (so the
// handler only runs for signed-in users), then hands us:
//   ctx.supabase       a client acting AS THE CALLER, so RLS applies
//   ctx.supabaseAdmin  a service-role client that BYPASSES RLS (use deliberately)
//   ctx.userClaims     { id, email, role, appMetadata, userMetadata } from the verified JWT
//
// Local URL: http://127.0.0.1:54321/functions/v1/whoami   (served by `supabase start`)
// Deploy:    npx supabase functions deploy whoami

import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

export default {
  fetch: withSupabase({ auth: "user" }, async (_req, ctx) => {
    // RLS-scoped: counts only the caller's own todos.
    const { data: stats, error } = await ctx.supabase.rpc("my_todo_stats");
    if (error) return Response.json({ error: error.message }, { status: 500 });

    // Admin client: a safe aggregate across ALL users (never return raw rows from this).
    const { count: totalTodos } = await ctx.supabaseAdmin
      .from("todos")
      .select("*", { count: "exact", head: true });

    return Response.json({
      message: `Hello ${ctx.userClaims?.email}!`,
      user_id: ctx.userClaims?.id,
      role: ctx.userClaims?.role,
      my_stats: stats?.[0],
      todos_in_whole_app: totalTodos,
      runtime: `Deno ${Deno.version.deno}`,
    });
  }),
};
